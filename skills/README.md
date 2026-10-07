# InnoRouter AI skill

The canonical skill lives in [innorouter/](innorouter/SKILL.md). API guidance,
references and the remote consumer fixture are maintained with this library.
[innosquad-agent-skills](https://github.com/InnoSquadCorp/innosquad-agent-skills)
packages immutable copies for Codex and Claude Code and owns installed-host AI
evaluations. The skill source commit and validated library revision are independent.

Planned support is stable **7.0.x** (`>=7.0.0 <7.1.0`). The current fixture pins
unreleased main `851c63f095e49b700c3a0aa8152a3521a39977e7`, intended for 7.0.0;
it is not released-tag evidence. See [support](innorouter/references/support.json)
and [validation](validation.md). Qualify the actual release tag before calling
this a released 7.0.0 baseline; later patches need their own consumer checks.

For standalone installation, copy the complete `innorouter` directory to
`.agents/skills/innorouter` (Codex) or `.claude/skills/innorouter` (Claude Code),
comparing any existing destination first. Preserve all supporting files and modes.
Invoke `$innorouter` or `/innorouter`; automatic discovery is also enabled.
The central plugin uses `$innosquad:innorouter` or `/innosquad:innorouter`.

Run `python3 skills/innorouter/scripts/validate_consumer.py --scratch-path
/tmp/innorouter-skill-validation` for an isolated exact-candidate consumer.
Do not include local build products or credentials in the skill.
