---
name: Feature request
about: Suggest something
labels: enhancement
---

## What you want to do

Describe the task, not the implementation.

## Why the current behaviour gets in the way

## Anything you have already tried

## If this is about another language

Term repair is Turkish-only on purpose: the guard that stops it overwriting a
real word is a Turkish word list, so elsewhere it corrupts text rather than
repairing it. Adding a language means supplying its common-word list and
phonetic normalisation. Say which language and whether you can help with that
data — transcription itself already works in any language Whisper supports.
