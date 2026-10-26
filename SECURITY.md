# Security Policy

## Scope

This repository contains RTL and testbenches. It is a design study, not a
production CPU, and it is **not hardened**: there is no fault-attack resistance,
no speculative-execution mitigation, and no formal guarantee that the PMP or the
privilege checks are free of bypasses. Do not deploy it in a security boundary.

## Reporting a vulnerability

Please do not report security issues through public GitHub Issues, Discussions
or pull requests.

Use GitHub's private vulnerability reporting:

1. Go to the **Security** tab of this repository.
2. Click **Report a vulnerability**.
3. Describe the issue, the affected file, and how to reproduce it.

What is most useful: a minimal program that demonstrates the behaviour, and the
simulator plus version you used. If you have a proof of concept that the PMP or
the CSR privilege checks can be bypassed, that is exactly the kind of report
worth sending.

## What to expect

This is a personal project, so there is no response SLA. Reports about the
verification methodology — a test that cannot fail, an oracle that is wrong —
are as welcome as reports about the RTL.
