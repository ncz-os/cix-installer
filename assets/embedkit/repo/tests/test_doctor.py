import pytest
import sys
sys.path.insert(0, 'src')
import embedkit.doctor

def test_doctor():
    embedkit.doctor.main()
