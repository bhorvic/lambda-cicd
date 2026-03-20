import sys
import os

# Allow running tests from repo root or tests/ directory
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'src'))


def test_handler():
    from lambda_function import lambda_handler
    result = lambda_handler({'test': 'data'}, None)
    assert result['statusCode'] == 200, f"Expected 200, got {result['statusCode']}"
    print("✓ test_handler passed!")


def test_handler_body():
    import json
    from lambda_function import lambda_handler
    result = lambda_handler({}, None)
    body = json.loads(result['body'])
    assert 'message' in body, "Response body missing 'message' key"
    print("✓ test_handler_body passed!")


if __name__ == "__main__":
    test_handler()
    test_handler_body()
    print("\n✓ All tests passed!")
