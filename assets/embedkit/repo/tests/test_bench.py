import pytest
import sys
sys.path.insert(0, 'src')
import embedkit.bench

def test_bench():
    embedkit.bench.main()
