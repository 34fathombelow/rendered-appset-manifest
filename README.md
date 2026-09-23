# rendered/addons -- generated branch

Every file here is produced by `scripts/render.sh` from `appsets/addons.yaml`
on `main`. Do not edit it by hand: CI opens one pull request per environment
(`render/addons/<env>`) against this branch, and merging that PR is what
deploys the change to that environment.

Layout: `<env>/<application-name>.yaml`, one ArgoCD Application per file.
