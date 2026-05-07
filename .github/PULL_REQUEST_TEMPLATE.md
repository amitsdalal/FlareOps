<!--
Thanks for contributing to FlareOps! Fill in what's relevant and delete the
rest. PRs without a clear motivation or test plan are likely to bounce.
-->

## What & why

<!-- Short summary of the change. Link any related issue or discussion. -->

Closes #

## Type of change

- [ ] Bug fix
- [ ] New feature / module
- [ ] Documentation update
- [ ] CI / tooling
- [ ] Breaking change (please call out the migration path below)

## Test plan

<!--
List the concrete commands you ran or actions you exercised. For changes to
purge-cache, at minimum:
  - bash purge-cache/tests/basic-test.sh
  - shellcheck purge-cache/scripts/*.sh
For new modules, link to the new test file.
-->

- [ ]
- [ ]

## Checklist

- [ ] Scripts pass `shellcheck -s bash`
- [ ] `bash purge-cache/tests/basic-test.sh` passes locally
- [ ] Updated `CHANGELOG.md` (if user-visible behavior changed)
- [ ] Updated module `README.md` and root `README.md` (if inputs/outputs changed)
- [ ] No secrets, tokens, or zone IDs committed
- [ ] Comments explain the WHY, not the WHAT
