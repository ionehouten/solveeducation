# REVIEW

## Summary

I reviewed this codebase the way I would a teammate's PR before it goes anywhere near production.

The most urgent problems are around secrets: a `.env` file with real-looking credentials was committed to the repo, the same password is hardcoded in three places (app, Dockerfile, Terraform variable), and the ECS task is running with full AWS `AdministratorAccess`. On top of that, every port is open to the internet on a Fargate task that has no SSH daemon, and there's no visibility into whether the service is actually healthy.
The changes are split into two pull requests by priority:
