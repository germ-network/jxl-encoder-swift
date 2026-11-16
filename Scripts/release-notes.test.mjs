import test from "node:test";

test.todo('extracts only the requested version section and ignores headings inside fences');
test.todo('fails for a missing or empty version section');
test.todo('preserves short notes and appends the permanent tagged changelog link');
test.todo('caps oversized notes at 120000 UTF16 units including the footer');
test.todo('cuts at a complete line without splitting Unicode surrogate pairs');
test.todo('omits an oversized first line rather than cutting it midline');
test.todo('closes an open backtick or tilde fence before the footer');
test.todo('rejects invalid or insufficient budgets');
test.todo('CLI writes notes and fails without output for invalid input');
