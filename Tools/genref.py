"""Generate ground-truth PCA numbers for the Swift Accelerate port.

Imports the real rotations.py (pure numpy) and inlines the exact `_do_pca_2d`
from core.py so the Swift port can be validated against identical math.
"""
import importlib.util, json, sys
import numpy as np

SRC = "/Users/molfesepj/Documents/Programming/mne-erppcatoolkit/src/mne_erppca/pca"

spec = importlib.util.spec_from_file_location("rotations", f"{SRC}/rotations.py")
rot = importlib.util.module_from_spec(spec); spec.loader.exec_module(rot)
varimax, promax = rot.varimax, rot.promax


# ---- helpers copied verbatim from core.py ----
def _cross_product(data): return np.einsum("ij,ik->jk", np.conjugate(data), data, optimize=True)
def _matrix_product(a, b): return np.einsum("ij,jk->ik", a, b, optimize=True)
def _column_correlations(left, right):
    lc = left - np.mean(left, axis=0); rc = right - np.mean(right, axis=0)
    ls = np.std(lc, axis=0, ddof=1); rs = np.std(rc, axis=0, ddof=1)
    cov = _matrix_product(lc.T, rc) / (left.shape[0] - 1)
    return cov / ls[:, np.newaxis] / rs[np.newaxis, :]
def _pseudoinverse(matrix, rcond=1e-15):
    u, s, vh = np.linalg.svd(matrix, full_matrices=False)
    cutoff = rcond * np.max(s); si = np.zeros_like(s); si[s > cutoff] = 1.0 / s[s > cutoff]
    return _matrix_product(vh.conj().T * si[np.newaxis, :], u.conj().T)
def _unique_factor_variance(fac_pat, fac_cor, var_diag, denom):
    inv = np.linalg.solve(fac_cor, np.eye(fac_cor.shape[0]))
    scale = np.sqrt(np.diag(inv)); adjusted = fac_pat / scale[np.newaxis, :]
    return np.sum(var_diag[:, np.newaxis] * adjusted**2, axis=0) / denom
def _apply_loading(loadings, data, loading, n_factors):
    communalities = np.sum(loadings**2, axis=1)
    state = {"loading": loading, "communalities": communalities, "var_sd": np.std(data, axis=0, ddof=1)}
    if loading == "K":
        return loadings / np.sqrt(communalities)[:, np.newaxis], state
    if loading == "N":
        return loadings, state
    raise ValueError(loading)
def _undo_loading(fac_pat, fac_str, state):
    loading = state["loading"]; communalities = state["communalities"]
    if loading == "K":
        scale = np.sqrt(communalities)[:, np.newaxis]; return scale * fac_pat, scale * fac_str
    if loading == "N":
        return fac_pat, fac_str
    raise ValueError(loading)


def do_pca_2d(data, *, rotation, n_factors, matrix_type="COV", loading="K", rotopt=3,
              random_state=0, algorithm="SAS"):
    data = np.asarray(data, dtype=float)
    bad_data = np.isnan(data)
    n_obs, n_vars = data.shape
    good_vars = (np.std(data, axis=0, ddof=1) != 0) & ~np.all(bad_data, axis=0)
    good_obs = ~np.any(bad_data[:, good_vars], axis=1)
    work = data[good_obs][:, good_vars]
    var_sd = np.std(work, axis=0, ddof=1); var_mean = np.mean(work, axis=0)
    if matrix_type == "SCP": relation_data = work
    elif matrix_type == "COV": relation_data = work - var_mean
    elif matrix_type == "COR": relation_data = (work - var_mean) / var_sd
    relation = _cross_product(relation_data) / (work.shape[0] - 1)
    sd_relation = np.sqrt(np.diag(relation))
    eig_vals, eig_vecs = np.linalg.eigh(relation)
    order = np.argsort(eig_vals)[::-1]
    eig_vals = eig_vals[order]; eig_vecs = eig_vecs[:, order]
    scree = eig_vals.copy(); eig_vecs = eig_vecs[:, :n_factors]
    score_coefficients = eig_vecs if matrix_type in {"SCP", "COV"} else eig_vecs / var_sd[:, np.newaxis]
    fac_scr = _matrix_product(work, score_coefficients)
    scr_sd = np.std(fac_scr, axis=0, ddof=1)
    loadings = (eig_vecs * scr_sd) / sd_relation[:, np.newaxis]
    loadings, loading_state = _apply_loading(loadings, work, loading, n_factors)
    if rotation == "unrotated":
        fac_pat = loadings; fac_cor = np.eye(n_factors); fac_str = fac_pat
    elif rotation == "varimax":
        fac_pat = varimax(loadings, random_state=random_state); fac_cor = np.eye(n_factors); fac_str = fac_pat
    elif rotation == "promax":
        vmx = varimax(loadings, random_state=random_state)
        fac_pat, fac_cor = promax(vmx, power=rotopt, algorithm=algorithm)
        fac_str = _matrix_product(fac_pat, fac_cor)
    fac_pat, fac_str = _undo_loading(fac_pat, fac_str, loading_state)
    fac_cof = _pseudoinverse(sd_relation[:, np.newaxis] * fac_pat).T
    fac_scr = _matrix_product(work, fac_cof)
    fac_scr = fac_scr / np.std(fac_scr, axis=0, ddof=1)
    var_diag = sd_relation**2; denom = np.sum(var_diag)
    communalities = np.sum((var_diag[:, np.newaxis] * fac_pat) * fac_str, axis=1) / denom
    fac_var = np.sum((var_diag[:, np.newaxis] * fac_pat) * fac_str, axis=0) / denom
    fac_var_q = _unique_factor_variance(fac_pat, fac_cor, var_diag, denom)
    fac_var_tot = float(np.sum(communalities))
    index = np.argsort(fac_var)[::-1]
    fac_pat = fac_pat[:, index]; fac_str = fac_str[:, index]; fac_cof = fac_cof[:, index]
    fac_scr = fac_scr[:, index]; fac_cor = fac_cor[np.ix_(index, index)]
    fac_var = fac_var[index]; fac_var_q = fac_var_q[index]
    for f in range(fac_pat.shape[1]):
        if np.sum(fac_pat[:, f]) < 0:
            fac_pat[:, f] *= -1; fac_str[:, f] *= -1; fac_cof[:, f] *= -1
            fac_scr[:, f] *= -1; fac_cor[:, f] *= -1; fac_cor[f, :] *= -1
    return dict(scree=scree.tolist(), fac_pat=fac_pat.tolist(), fac_str=fac_str.tolist(),
                fac_cor=fac_cor.tolist(), fac_var=fac_var.tolist(), fac_var_q=fac_var_q.tolist(),
                fac_var_tot=fac_var_tot)


# Fixed, fully-deterministic 9x5 input with two latent factors.
rng = np.random.default_rng(7)
f1 = rng.standard_normal(9); f2 = rng.standard_normal(9)
loadings_true = np.array([[1.0, 0.0],[0.9, 0.1],[0.0, 1.0],[0.1, 0.8],[0.7, 0.5]])
data = (np.outer(f1, loadings_true[:, 0]) + np.outer(f2, loadings_true[:, 1])
        + 0.05 * rng.standard_normal((9, 5)))
data = np.round(data, 6)

out = {"input": data.tolist(),
       "unrotated": do_pca_2d(data, rotation="unrotated", n_factors=2),
       "promax": do_pca_2d(data, rotation="promax", n_factors=2)}
print(json.dumps(out))
