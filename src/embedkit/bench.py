import argparse

def main():
    parser = argparse.ArgumentParser(description='Embedkit Bench')
    parser.add_argument('--help', action='help', help='Show this help message and exit')
    args = parser.parse_args()
    # Add benchmarking logic here
