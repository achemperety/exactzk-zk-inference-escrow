import sys, json

stdout_log, time_log, circuit, results_path = sys.argv[1:5]

result_line = None
with open(stdout_log) as f:
    for line in f:
        if line.startswith("RESULT_JSON:"):
            result_line = line[len("RESULT_JSON:"):].strip()
d = json.loads(result_line)
d["circuit"] = circuit

ext_rss = None
with open(time_log) as f:
    for line in f:
        if "maximum resident set size" in line:
            ext_rss = int(line.split()[0])
d["external_time_l_peak_rss_bytes"] = ext_rss

with open(results_path, "a") as f:
    f.write(json.dumps(d) + "\n")

print(json.dumps(d))
