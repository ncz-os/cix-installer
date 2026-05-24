import pytest
import sys
import embedkit.bench
import embedkit.doctor

def test_bench_help():
    sys.argv = ['embedkit.bench', '--help']
    embedkit.bench.main()

def test_doctor_help():
    sys.argv = ['embedkit.doctor', '--help']
    embedkit.doctor.main()
