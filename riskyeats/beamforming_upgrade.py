import numpy as np
from sklearn.metrics import accuracy_score

def beamform_upgrade(dbpr, eos, rdar, news, sentiment):
    # Beamform → composite risk signal + DOA tells us 'closure risk dominated by EOS signal' or 'rodent risk dominated by news complaint signal'
    beamformed_signal = ...
    return beamformed_signal
