import sys

from companion_agent import PROTOCOL_VERSION


def test_runtime_contract():
    assert sys.version_info[:2] == (3, 12)
    assert PROTOCOL_VERSION == 1
