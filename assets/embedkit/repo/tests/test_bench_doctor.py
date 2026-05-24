import pytest
import sys
sys.path.append('assets/embedkit/repo/src')
import embedkit.bench
import embedkit.doctor

def test_bench_help():
    assert embedkit.bench.main(['--help']) == 0

def test_doctor_help():
    assert embedkit.doctor.main(['--help']) == 0
