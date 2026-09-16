# Project Instructions

The project workspace is `C:\Work\MatLab_Lib`. All SerDes modeling code and related project work must be performed within this directory.

This project implements an end-to-end behavioral SerDes model.

## Default Agent Model and Role Split

- For modeling-task solution discussion and code review, the primary agent must use `gpt-5.6-sol` with `high` reasoning effort by default.
- For coding implementation, the primary agent must delegate the work to a sub-agent using `gpt-5.6-sol` with `medium` reasoning effort by default, while the primary agent retains responsibility for scope alignment, final review, and verification.
- When a sub-agent model or reasoning override is needed, spawn it with `fork_turns="none"` or a positive turn count so the requested override can be applied.
- An explicit user instruction for a task overrides these defaults.

## Before Starting a Task

Read the following files in order before beginning any work:

1. `README.md`
2. `docs/ARCHITECTURE.md`
3. `docs/MODEL_ASSUMPTIONS.md`
4. `docs/CURRENT_STATE.md`
5. `docs/DECISIONS.md`
6. `docs/VALIDATION.md`

After reading them, provide a summary in no more than 10 lines covering:

- Current model status
- Validated capabilities
- Current blockers
- Recommended objective for the task

Do not change any key physical assumptions without explicit user confirmation.

## Modeling Constraints

- Record every approximation in `docs/MODEL_ASSUMPTIONS.md`.

## Before Completing a Task

You must:

1. Run the relevant tests.
2. Update `docs/CURRENT_STATE.md`.
3. Update `docs/DECISIONS.md` if any design decision changed.
4. Update `docs/MODEL_ASSUMPTIONS.md` if any modeling assumption changed.
5. Provide a suggested Git commit message.
