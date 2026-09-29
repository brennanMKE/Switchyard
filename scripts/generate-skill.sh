#!/usr/bin/env zsh
#
# generate-skill.sh — rewrite skills/switchyard/SKILL.md from the code (#0066).
#
# The skill is rendered by renderSkill() in YardKit/Sources/YardKit/SkillRenderer.swift
# from CommandRegistry.all plus the prose in SkillProse.swift. This runs the golden
# test with SKILL_REGENERATE=1, which writes the file and then checks it, the same
# way SCHEMA_REGENERATE=1 rewrites YardKit/Schemas/. Never edit SKILL.md by hand.

set -eu
cd "${0:A:h:h}/YardKit"
SKILL_REGENERATE=1 swift test --filter SkillGoldenTests
