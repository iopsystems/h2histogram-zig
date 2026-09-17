"""Independent integer bucket intervals for native-port compatibility tests."""
import csv
import io
import random
from pathlib import Path

rows = []
for gp, mvp in [(0,1),(0,8),(0,64),(1,2),(1,16),(3,16),(3,64),(7,32),(7,64),(10,64),(30,31)]:
    maximum = (1 << mvp) - 1
    total = (1 << gp) * (mvp - gp + 1)
    values = {0, 1, maximum}
    for power in range(mvp):
        for delta in [-1, 0, 1]:
            v = (1 << power) + delta
            if 0 <= v <= maximum: values.add(v)
    rng = random.Random((gp << 8) + mvp)
    values.update(rng.randrange(maximum + 1) for _ in range(64))
    for value in sorted(values):
        # Count complete exponent intervals, then subdivision at this exponent.
        if value < (1 << (gp + 1)):
            index = start = end = value
        else:
            exponent = value.bit_length() - 1
            width = 1 << (exponent - gp)
            start = (value // width) * width
            end = start + width - 1
            index = (1 << (gp + 1)) + (exponent - gp - 1) * (1 << gp) + ((value - (1 << exponent)) // width)
        rows.append((gp, mvp, value, index, start, end, total))
out = io.StringIO(); writer = csv.writer(out, lineterminator='\n')
writer.writerow(['gp','mvp','value','index','start','end','total_buckets']); writer.writerows(rows)
Path(__file__).with_name('geometry.csv').write_text(out.getvalue())
print(len(rows), 'geometry cases')
