#!/bin/bash
# s390x — single-CPU emulation; boot alone runs ~6 min under PAR=2 contention.
# 300s default kills cells before LTP starts; bump to 2400.
TIMEOUT=2400
