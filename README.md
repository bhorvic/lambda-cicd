# lambda-cicd

A lightweight CLI-driven CI/CD pipeline for deploying AWS Lambda functions, with a paired cleanup script for tearing down test resources.

## Repo Structure

```text
lambda-cicd/
├── scripts/
│   ├── deploy.sh        # Full build → package → upload → deploy → smoke test pipeline
│   └── cleanup.sh       # Delete configured Lambda resources and optional extras
├── src/
│   └── lambda_function.py   # Lambda handler (swap in your own)
├── tests/
│   └── test_lambda.py       # Unit tests run as part of the pipeline
├── config/
│   └── config.env.example   # Template for environment config
└── .gitignore
```

## Shell Requirement

The deploy and cleanup scripts require **bash**. They are not compatible with `sh`, PowerShell, or other shells.

- Linux / macOS: any terminal — bash is available by default
- Windows: use **Git Bash** (included with Git for Windows) or **WSL**

## Prerequisites

- AWS CLI installed and configured (`aws configure`)
- Python 3.x available on PATH
- `zip` installed and available on PATH
- An S3 bucket name specified in `config/config.env` — or leave it blank and let the deploy script create one automatically
- IAM permissions to manage Lambda functions, IAM roles, and S3

## Setup

```bash
# 1. Clone the repo
git clone https://github.com/bhorvic/lambda-cicd.git
cd lambda-cicd

# 2. Create your config file from the example
cp config/config.env.example config/config.env

# 3. Edit config/config.env with your values
#    REGION, FUNCTION_NAME, optional BUCKET_NAME / ROLE_NAME / EXTRA_FUNCTIONS / LAYER_NAME

# 4. Make scripts executable
chmod +x scripts/deploy.sh scripts/cleanup.sh
```

## Deploy

```bash
./scripts/deploy.sh
```

The pipeline runs these steps:

1. Run unit tests from `tests/test_lambda.py`
2. Package `src/lambda_function.py` into a versioned zip
3. Create the S3 bucket if it doesn't exist (public access blocked)
4. Upload the zip to S3 under `lambda-builds/`
5. Create the Lambda function if it doesn't exist, otherwise update it
6. Wait for Lambda to finish provisioning/updating
7. Publish a numbered Lambda version
8. Invoke the published version as a smoke test
9. Clean up local build artifacts automatically

## Cleanup

```bash
./scripts/cleanup.sh
```

By default, cleanup deletes:

- the `FUNCTION_NAME` defined in `config/config.env`
- any comma-separated functions listed in `EXTRA_FUNCTIONS`
- all versions of the layer named by `LAYER_NAME`
- an auto-created S3 bucket, if `deploy.sh` created one

## Customizing the Lambda

Replace `src/lambda_function.py` with your own handler. The deploy script expects:

- **File**: `src/lambda_function.py`
- **Handler**: `lambda_function.lambda_handler`

Update `tests/test_lambda.py` to match your handler's expected inputs and outputs.

## Notes

- `config/config.env` is `.gitignore`d — never commit it, as it contains environment-specific values.
- The IAM role (`ROLE_NAME`) will be created automatically if it doesn't exist, with the `AWSLambdaBasicExecutionRole` managed policy attached.
- Build artifacts are written to `.build/` and are removed automatically even if the deploy script exits early.
- The smoke test validates the Lambda response JSON instead of checking for a raw string match.
