# -*- coding: utf-8 -*-
"""Emit inlined COT+SMC block for single-file GOLD_ORB_*.mq5 (no .mqh)."""
import pathlib

root = pathlib.Path(__file__).resolve().parent
cot_lines = root.joinpath("Gold_ORB_COT.mqh").read_text(encoding="utf-8").splitlines()
smc_lines = root.joinpath("Gold_ORB_SMC.mqh").read_text(encoding="utf-8").splitlines()

# Body: #define COT_MAX_ROWS .. COT_PassesDirectionFilter (exclude #ifndef/#endif)
cot_body_lines = cot_lines[22:457]


def find_idx(lines, prefix):
    for i, ln in enumerate(lines):
        if ln.strip().startswith(prefix):
            return i
    return -1


def extract_function(lines, start_idx):
    """From line starting at start_idx, through closing brace of function."""
    brace = 0
    started = False
    for k in range(start_idx, len(lines)):
        line = lines[k]
        for ch in line:
            if ch == "{":
                brace += 1
                started = True
            elif ch == "}":
                brace -= 1
        if started and brace == 0:
            return lines[start_idx : k + 1]
    raise RuntimeError("unclosed function from line " + str(start_idx))


i_sort = find_idx(cot_body_lines, "void COT_SortAscending")
i_fetch = find_idx(cot_body_lines, "bool COT_FetchCftcGoldWeb")
if i_sort < 0 or i_fetch < 0:
    raise SystemExit("anchors missing: sort=%s fetch=%s" % (i_sort, i_fetch))

sort_chunk = extract_function(cot_body_lines, i_sort)
end_sort = i_sort + len(sort_chunk)

without_sort = cot_body_lines[:i_sort] + cot_body_lines[end_sort:]
i_fetch_new = find_idx(without_sort, "bool COT_FetchCftcGoldWeb")
if i_fetch_new < 0:
    raise SystemExit("COT_FetchCftcGoldWeb not found after removing sort")

reordered_cot = (
    without_sort[:i_fetch_new] + [""] + sort_chunk + [""] + without_sort[i_fetch_new:]
)

cot_out = "\n".join(reordered_cot)

# SMC: struct through SMC_PassesShortFilter (drop header guards)
smc_body = "\n".join(smc_lines[9:522])

header = """//+------------------------------------------------------------------+
//| Inlined: Gold_ORB_COT + Gold_ORB_SMC (single file — no separate .mqh)
//+------------------------------------------------------------------+

"""

block = header + cot_out + "\n\n" + smc_body + "\n"

out_path = root.joinpath("_inline_cot_smc_block.mqh")
out_path.write_text(block, encoding="utf-8")
print("Wrote", out_path, "chars", len(block))
