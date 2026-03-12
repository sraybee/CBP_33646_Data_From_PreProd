import re

def analyze(fname, steps):
    lines = open(fname).readlines()
    status_line = next((i for i,l in enumerate(lines) if l.startswith('status:')), len(lines))
    spec = ''.join(lines[:status_line])
    status = ''.join(lines[status_line:])
    c_line = next((i for i,l in enumerate(lines) if l == '  containers:\n'), 0)
    c_starts = [i for i,l in enumerate(lines) if l.startswith('  - ') and i >= c_line and i < status_line]

    def blk(idx):
        s = c_starts[idx]
        e = c_starts[idx+1] if idx+1 < len(c_starts) else status_line
        return ''.join(lines[s:e])

    def cenv(b): return len(re.findall(r'\n      - name: ', b))
    def cvm(b):  return len(re.findall(r'mountPath:', b))

    b0 = blk(0)
    b1 = blk(1)
    bm = blk(len(c_starts)//2)
    bl = blk(len(c_starts)-1)
    mid = len(c_starts)//2
    total_env = sum(cenv(blk(i)) for i in range(len(c_starts)))

    print('--- %d steps ---' % steps)
    print('  spec size:          %s bytes' % format(len(spec.encode()), ','))
    print('  status size:        %s bytes (runtime, at capture time)' % format(len(status.encode()), ','))
    print('  containers:         %d' % len(c_starts))
    print('  prepare-workspace:  %s bytes | env:%d | vm:%d' % (format(len(b0.encode()),','), cenv(b0), cvm(b0)))
    print('  step-s001 (1st):    %s bytes | env:%d | vm:%d' % (format(len(b1.encode()),','), cenv(b1), cvm(b1)))
    print('  step-s%03d (mid):    %s bytes | env:%d | vm:%d' % (mid, format(len(bm.encode()),','), cenv(bm), cvm(bm)))
    print('  step-s%03d (last):   %s bytes | env:%d | vm:%d' % (steps, format(len(bl.encode()),','), cenv(bl), cvm(bl)))
    print('  total env all ctrs: %d   avg: %d per container' % (total_env, total_env//len(c_starts)))
    print()

analyze('pod_yaml_105_steps.yaml', 105)
analyze('pod_yaml_160_steps.yaml', 160)
