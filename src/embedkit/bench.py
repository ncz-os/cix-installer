import sys
import argparse

def main():
    parser = argparse.ArgumentParser(description='EmbedKit bench command')
    parser.add_argument('--help', action='help', help='Show this help message and exit')
    args = parser.parse_args()
    if args.help:
        parser.print_help()
        sys.exit(0)
