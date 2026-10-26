# Publishing this tree as a private GitHub repository

The repository content is ready. Creating the remote and pushing needs
credentials this sandbox does not have on its own — pick whichever route suits
you.

## Option A — you push it (two commands)

From the unpacked `rv64_core/` directory:

```bash
git init -b main
git add .
git commit -m "rv64_core: RV64IM machine-mode core with cocotb verification environment"

# create the private repo and push in one step (needs the GitHub CLI, logged in)
gh repo create rv64_core --private --source=. --remote=origin --push
```

Without `gh`:

```bash
# create an empty PRIVATE repo named rv64_core in the browser first, then:
git remote add origin git@github.com:<your-account>/rv64_core.git
git push -u origin main
```

Verify it is private before pushing anything sensitive:

```bash
gh repo view --json visibility        # expect "PRIVATE"
```

## Option B — let the agent push it

This agent can drive `git`/`gh` in its sandbox once the **GitHub App**
connector is authorised for the session. If that is connected, ask and the agent
will run exactly the sequence above (`gh repo create … --private … --push`) and
report the resulting URL.

## CI

`.github/workflows/ci.yml` runs on every push and pull request: it installs
Icarus Verilog and cocotb, lints the RTL with `-Wall`, then runs both
regressions (`sim/run.py` and `sim/run.py --suite plic`). Private repositories
get the same free Actions minutes as public ones on GitHub's standard plans;
check your plan if the workflow does not start.

## Before the first push

* **Choose a license.** No `LICENSE` file is included — add the one you want.
  If this core is derived from or intended to be compatible with other RISC-V
  work, check the obligations of those licenses first.
* **Confirm no secrets.** The tree contains only RTL, testbenches and docs; no
  tokens, keys or internal hostnames.
* **Decide on the history.** A single initial commit is fine; if you want the
  design-review history, commit the RTL, testbench and docs separately.
