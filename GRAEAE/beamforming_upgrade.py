import numpy as np
from sklearn.metrics import accuracy_score

def beamform_upgrade(muse_scores, prior_question_performance):
    # Derive per-muse weight from prior-question performance on that question's class
    weights = ...
    # Beamform → cleaner consensus + DOA tells us WHICH muse drove the answer (transparency)
    beamformed_signal = ...
    return beamformed_signal, DOA
