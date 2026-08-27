import re

path = r"c:\Users\malco\OneDrive\Documents\GitHub\MetalBot\test_blueprint_placer.lua"

# In Lua 5.1, the 200-local limit is per *function prototype*.
# do/then/else/repeat blocks do NOT create new prototypes — their locals
# count toward the enclosing function.  Only `function ... end` does.
#
# Stack items pushed by:
#   function -> 'function'  (also increments function_depth)
#   if       -> 'if'
#   do       -> 'do'  (covers standalone do, while..do, for..do)
#   repeat   -> 'repeat'  (closed by 'until')
# then / elseif / else / until / for / while / return: no push
# end -> pops top of stack

function_depth = 0
block_stack = []
local_count = 0
locals_list = []

KW_RE = re.compile(r'\b(function|do|if|repeat|end|until|local)\b')

def strip_comment(line):
    in_str = None
    i = 0
    result = []
    while i < len(line):
        c = line[i]
        if in_str:
            if c == chr(92):  # backslash escape
                result.append(c)
                if i+1 < len(line):
                    result.append(line[i+1])
                i += 2
                continue
            if c == in_str:
                in_str = None
        else:
            if c in ('"', "'"):
                in_str = c
            elif c == '-' and i+1 < len(line) and line[i+1] == '-':
                return ''.join(result)
        result.append(c)
        i += 1
    return ''.join(result)

with open(path, encoding='utf-8') as f:
    for lineno, line in enumerate(f, 1):
        clean = strip_comment(line)
        keywords = KW_RE.findall(clean)

        # Count top-level local (check BEFORE updating depth for this line)
        if function_depth == 0 and keywords and keywords[0] == 'local':
            stripped = line.lstrip()
            if stripped.startswith('local'):
                local_count += 1
                locals_list.append((lineno, line.rstrip()[:72]))

        for kw in keywords:
            if kw == 'function':
                block_stack.append('function')
                function_depth += 1
            elif kw == 'if':
                block_stack.append('if')
            elif kw == 'do':
                block_stack.append('do')
            elif kw == 'repeat':
                block_stack.append('repeat')
            elif kw == 'until':
                if block_stack and block_stack[-1] == 'repeat':
                    block_stack.pop()
            elif kw == 'end':
                if block_stack:
                    closed = block_stack.pop()
                    if closed == 'function':
                        function_depth -= 1

print(f"Total top-level local declarations: {local_count}")
if local_count > 200:
    print(f"OVER LIMIT by {local_count - 200}")
else:
    print(f"Under limit by {200 - local_count}")
print()
if local_count > 195:
    print("All top-level locals:")
    for lineno, name in locals_list:
        print(f"  {lineno:5d}: {name}")
else:
    print("Last 20 top-level locals:")
    for lineno, name in locals_list[-20:]:
        print(f"  {lineno:5d}: {name}")
print(f"\nFinal stack depth: {function_depth}, stack size: {len(block_stack)}")
