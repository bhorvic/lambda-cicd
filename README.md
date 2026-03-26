# lambda-cicd

A lightweight CLI-driven CI/CD pipeline for deploying AWS Lambda functions, with a paired cleanup script for tearing down test resources.

## Repo Structure

```
lambda-cicd/
├── scripts/
│   ├── deploy.sh        # Full build → package → upload → deploy → smoke test pipeline
│   └── cleanup.sh       # Delete test Lambda functions and layers
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

| OS | How to run |
|----|------------|
| Linux / macOS | Any terminal — bash is available by default |
| Windows | Use **Git Bash** (included with [Git for Windows](https://git-scm.com/downloads)) or **WSL** (Windows Subsystem for Linux) |

To open Git Bash on Windows, right-click a folder and select **Git Bash Here**, or launch it from the Start menu.

## Prerequisites

- AWS CLI installed and configured (`aws configure`)
- Python 3.x available on PATH
- An S3 bucket name specified in `config/config.env` — will be created automatically if it doesn't exist
- IAM permissions to manage Lambda functions, IAM roles, and S3

## Setup

```bash
# 1. Clone the repo
git clone https://github.com/bhorvic/lambda-cicd.git
cd lambda-cicd

# 2. Create your config file from the example
cp config/config.env.example config/config.env

# 3. Edit config/config.env with your values
#    REGION, BUCKET_NAME, FUNCTION_NAME, ROLE_NAME

# 4. Make scripts executable
chmod +x scripts/deploy.sh scripts/cleanup.sh
```

## Deploy

```bash
./scripts/deploy.sh
```

The pipeline runs these steps:

| Step | Description |
|------|-------------|
| 1    | Run unit tests from `tests/test_lambda.py` |
| 2    | Package `src/lambda_function.py` into a versioned zip |
| 3    | Create S3 bucket if it doesn't exist (public access blocked) |
| 4    | Upload zip to S3 (`lambda-builds/` prefix) |
| 5    | Create the Lambda function if it doesn't exist, otherwise update it |
| 6    | Publish a numbered Lambda version |
| 7    | Invoke the published version as a smoke test |
| 8    | Clean up local build artifacts |

## Cleanup

```bash
./scripts/cleanup.sh
```

Deletes the Lambda functions listed in `FUNCTIONS` and all versions of the `requests-layer` Lambda layer. Edit those arrays at the top of the script to match your environment.

## Customizing the Lambda

Replace `src/lambda_function.py` with your own handler. The deploy script expects:

- **File**: `src/lambda_function.py`
- **Handler**: `lambda_function.lambda_handler`

Update `tests/test_lambda.py` to match your handler's expected inputs and outputs.

## Notes

- `config/config.env` is `.gitignore`d — never commit it, as it contains environment-specific values.
- The IAM role (`ROLE_NAME`) will be created automatically if it doesn't exist, with the `AWSLambdaBasicExecutionRole` managed policy attached.
- Build artifacts are written to `.build/` (also `.gitignore`d) and cleaned up after a successful deploy.
