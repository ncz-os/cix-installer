import pytest
import os


def pytest_runtest_setup(item):
    """
    Skip tests marked with 'requires_npu' if NPU is not available.
    """
    if "requires_npu" in item.keywords:
        # Simple check: if we can import noe_engine, assume NPU is available
        try:
            import noe_engine
            # Further checks could verify device availability
        except ImportError:
            pytest.skip("NPU not available, skipping NPU-only test")
