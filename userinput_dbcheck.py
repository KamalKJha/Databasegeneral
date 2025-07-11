import json
import os
import boto3
import logging
import sys
import argparse
from datetime import datetime

# Configure logging for the script
logger = logging.getLogger(__name__)
logger.setLevel(os.environ.get('LOG_LEVEL', 'INFO').upper()) # Default log level is INFO

# Configure console handler for logging
handler = logging.StreamHandler(sys.stdout)
formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
handler.setFormatter(formatter)
logger.addHandler(handler)

# Initialize AWS clients globally
try:
    rds_client = boto3.client('rds')
    s3_client = boto3.client('s3')
    
    S3_BUCKET_NAME = os.environ.get('S3_BUCKET_NAME')

    logger.info("Initialized AWS clients.")
    if not S3_BUCKET_NAME:
        logger.error("FATAL: S3_BUCKET_NAME environment variable is not set. Results cannot be stored in S3.")
        sys.exit(1) # Exit if critical environment variable is missing

except Exception as e:
    logger.error(f"FATAL: Error initializing AWS clients. Ensure boto3 is configured and IAM role has necessary permissions: {e}")
    sys.exit(1) # Exit on critical initialization failure

def get_rds_instance_details(db_identifier):
    """
    Fetches detailed configuration information for a given AWS RDS DB instance.

    Args:
        db_identifier (str): The identifier of the RDS DB instance to retrieve.

    Returns:
        dict: A dictionary containing the details of the RDS instance if found,
              otherwise None. Handles DBInstanceNotFoundFault specifically.
    """
    logger.info(f"Attempting to fetch details for RDS instance: {db_identifier}")
    try:
        response = rds_client.describe_db_instances(DBInstanceIdentifier=db_identifier)
        if response and response.get('DBInstances'):
            logger.info(f"Successfully fetched details for {db_identifier}")
            return response['DBInstances'][0]
        else:
            logger.warning(f"No RDS instance found with identifier: {db_identifier}. Response: {response}")
            return None
    except rds_client.exceptions.DBInstanceNotFoundFault:
        logger.error(f"RDS instance '{db_identifier}' not found. Please check the identifier.")
        return None
    except Exception as e:
        logger.error(f"An unexpected error occurred while fetching details for RDS instance '{db_identifier}': {e}")
        return None

def compare_rds_fields(db1_details, db2_details, fields_to_compare):
    """
    Compares specified configuration fields between two RDS instance detail dictionaries.
    This function handles basic types and common complex types like lists of dictionaries
    (e.g., VpcSecurityGroups).

    Args:
        db1_details (dict): Details of the first RDS instance.
        db2_details (dict): Details of the second RDS instance.
        fields_to_compare (list): A list of strings, where each string is the name
                                  of an RDS configuration field to compare.

    Returns:
        dict: A dictionary containing the overall comparison status and any differences found.
              Example:
              {
                  "status": "SUCCESS" | "DIFFERENCES_FOUND" | "ERROR",
                  "message": "...",
                  "differences": {
                      "FieldName": {
                          "db1": "value1",
                          "db2": "value2",
                          "diff": true
                      },
                      ...
                  }
              }
    """
    comparison_results = {
        "status": "SUCCESS",
        "message": "No differences found for specified fields.",
        "differences": {}
    }

    if not db1_details or not db2_details:
        comparison_results["status"] = "ERROR"
        comparison_results["message"] = "One or both DB instance details are missing for comparison."
        logger.error(comparison_results["message"])
        return comparison_results

    logger.info(f"Starting comparison of fields: {fields_to_compare}")
    found_differences = False

    for field in fields_to_compare:
        value1 = db1_details.get(field)
        value2 = db2_details.get(field)

        if isinstance(value1, list) and isinstance(value2, list):
            if field == 'VpcSecurityGroups':
                ids1 = sorted([sg.get('VpcSecurityGroupId') for sg in value1 if sg.get('VpcSecurityGroupId')])
                ids2 = sorted([sg.get('VpcSecurityGroupId') for sg in value2 if sg.get('VpcSecurityGroupId')])
                if ids1 != ids2:
                    found_differences = True
                    comparison_results["differences"][field] = {
                        "db1": ids1,
                        "db2": ids2,
                        "diff": True
                    }
                else:
                    comparison_results["differences"][field] = {
                        "db1": ids1,
                        "db2": ids2,
                        "diff": False
                    }
            else:
                if sorted(value1) != sorted(value2):
                    found_differences = True
                    comparison_results["differences"][field] = {
                        "db1": value1,
                        "db2": value2,
                        "diff": True
                    }
                else:
                    comparison_results["differences"][field] = {
                        "db1": value1,
                        "db2": value2,
                        "diff": False
                    }
        elif isinstance(value1, dict) and isinstance(value2, dict):
            str_value1 = json.dumps(value1, sort_keys=True)
            str_value2 = json.dumps(value2, sort_keys=True)
            if str_value1 != str_value2:
                found_differences = True
                comparison_results["differences"][field] = {
                    "db1": value1,
                    "db2": value2,
                    "diff": True
                }
            else:
                comparison_results["differences"][field] = {
                    "db1": value1,
                    "db2": value2,
                    "diff": False
                }
        elif value1 != value2:
            found_differences = True
            comparison_results["differences"][field] = {
                "db1": str(value1),
                "db2": str(value2),
                "diff": True
            }
        else:
            comparison_results["differences"][field] = {
                "db1": str(value1),
                "db2": str(value2),
                "diff": False
            }

    if found_differences:
        comparison_results["status"] = "DIFFERENCES_FOUND"
        comparison_results["message"] = "Differences found for one or more specified fields."
    
    logger.info(f"Comparison complete. Overall status: {comparison_results['status']}")
    return comparison_results

def store_comparison_results_to_s3(db1_identifier, db2_identifier, comparison_output):
    """
    Stores the detailed comparison results as a JSON file in the configured S3 bucket.

    Args:
        db1_identifier (str): Identifier of the first DB instance.
        db2_identifier (str): Identifier of the second DB instance.
        comparison_output (dict): The output dictionary from compare_rds_fields.

    Returns:
        str: The S3 object key if storage was successful, None otherwise.
    """
    if not S3_BUCKET_NAME:
        logger.error("S3_BUCKET_NAME is not set. Cannot store results in S3.")
        return None

    try:
        timestamp = datetime.now().strftime('%Y/%m/%d/%H%M%S%f')
        s3_object_key = f"rds-comparison-results/{db1_identifier}-vs-{db2_identifier}/{timestamp}.json"
        
        file_content = json.dumps(comparison_output, indent=4)
        
        s3_client.put_object(
            Bucket=S3_BUCKET_NAME,
            Key=s3_object_key,
            Body=file_content,
            ContentType='application/json'
        )
        logger.info(f"Comparison results for {db1_identifier} vs {db2_identifier} stored in S3: s3://{S3_BUCKET_NAME}/{s3_object_key}")
        return s3_object_key
    except Exception as e:
        logger.error(f"Error storing comparison results in S3 for {db1_identifier} vs {db2_identifier}: {e}")
        return None

def main():
    """
    Main function to parse arguments, perform RDS comparison, and report status.
    """
    parser = argparse.ArgumentParser(description="Compare AWS RDS instance configurations and store results in S3.")
    parser.add_argument('--db1-identifier', required=True, help="Identifier for the first RDS instance.")
    parser.add_argument('--db2-identifier', required=True, help="Identifier for the second RDS instance.")
    parser.add_argument('--fields-to-compare', required=True, 
                        help="Comma-separated list of RDS fields to compare (e.g., 'DBInstanceClass,EngineVersion,MultiAZ').")
    
    args = parser.parse_args()

    db1_identifier = args.db1_identifier
    db2_identifier = args.db2_identifier
    fields_to_compare = [field.strip() for field in args.fields_to_compare.split(',')]

    logger.info(f"Script initiated with DB1: '{db1_identifier}', DB2: '{db2_identifier}', Fields: {fields_to_compare}")

    # Validate essential input parameters
    if not all([db1_identifier, db2_identifier, fields_to_compare]):
        logger.error("Missing required input parameters. Please provide --db1-identifier, --db2-identifier, and --fields-to-compare.")
        sys.exit(1)
    
    if not isinstance(fields_to_compare, list) or not all(isinstance(f, str) for f in fields_to_compare):
        logger.error("'fields_to_compare' must be a comma-separated list of strings.")
        sys.exit(1)

    # Fetch details for both RDS instances
    db1_details = get_rds_instance_details(db1_identifier)
    db2_details = get_rds_instance_details(db2_identifier)

    if not db1_details or not db2_details:
        logger.error("Could not retrieve details for one or both specified RDS instances. Exiting.")
        sys.exit(1)

    # Perform the actual comparison of RDS fields
    comparison_output = compare_rds_fields(db1_details, db2_details, fields_to_compare)
    logger.info(f"Raw comparison output: {json.dumps(comparison_output, indent=2)}")

    # Store the comparison results in S3
    s3_object_key = store_comparison_results_to_s3(db1_identifier, db2_identifier, comparison_output)
    if not s3_object_key:
        logger.warning("Failed to store comparison results in S3. This might indicate an issue with S3 access.")
        # Decide if S3 storage failure should cause script failure.
        # For now, we'll let the comparison result dictate the exit code.

    # Determine the final exit code based on comparison results
    if comparison_output["status"] == "SUCCESS":
        logger.info("RDS configuration comparison successful: No differences found.")
        print(json.dumps({
            "status": "SUCCESS",
            "message": "No differences found.",
            "s3_location": f"s3://{S3_BUCKET_NAME}/{s3_object_key}" if s3_object_key else "S3 storage failed."
        }, indent=2))
        sys.exit(0) # Exit with success code
    elif comparison_output["status"] == "DIFFERENCES_FOUND":
        logger.warning("RDS configuration comparison found differences.")
        print(json.dumps({
            "status": "DIFFERENCES_FOUND",
            "message": "Differences found.",
            "differences": comparison_output["differences"],
            "s3_location": f"s3://{S3_BUCKET_NAME}/{s3_object_key}" if s3_object_key else "S3 storage failed."
        }, indent=2))
        sys.exit(1) # Exit with failure code
    else: # comparison_output["status"] == "ERROR"
        logger.error(f"An error occurred during RDS comparison: {comparison_output['message']}. Exiting.")
        print(json.dumps({
            "status": "ERROR",
            "message": comparison_output['message'],
            "s3_location": f"s3://{S3_BUCKET_NAME}/{s3_object_key}" if s3_object_key else "S3 storage failed."
        }, indent=2))
        sys.exit(1) # Exit with failure code

if __name__ == "__main__":
    main()
