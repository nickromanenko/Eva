# Eva

Eva — the first AI made for women. An AI assistant that considers each woman's physiology, hormonal cycle, emotional state, habits, and goals, helping her care for her physical and mental health and enter her Prime Era on her own terms.

## Repo layout

| Folder | What | Stack | Deploys to |
|---|---|---|---|
| `api/` | Backend API | Hono + Bun (Docker) | Google Cloud Run (`us-central1`) |
| `website/` | Landing site (landing, privacy, terms) | Astro (static) | Firebase Hosting |
| `mobile/` | iOS app | SwiftUI, iOS 18+, XcodeGen | App Store (later; Firebase App Distribution for betas) |
| root | Firebase config & security rules | `firebase.json`, `firestore.rules`, `storage.rules` | — |

Backend services: Firestore, Firebase Auth, Firebase Storage.

## Prerequisites

- [Bun](https://bun.sh) ≥ 1.3
- Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- `firebase-tools`, `gcloud`, Docker (for deploy/infra work only)

## Quickstart

```sh
# API — http://localhost:3000, GET /health
cd api && bun install && bun run dev

# Website — http://localhost:4321
cd website && bun install && bun run dev

# iOS app
cd mobile && xcodegen generate && open Eva.xcodeproj
```

> **Important:** `mobile/Eva.xcodeproj` is generated and gitignored — never edit it directly.
> Edit `mobile/project.yml` and re-run `xcodegen generate`. Re-run it after every fresh clone.

The Firebase iOS SDK is not added yet; when needed, uncomment the `packages:`/`dependencies:` blocks in `mobile/project.yml` and drop `GoogleService-Info.plist` into `mobile/Eva/`.

## Deployment (GitHub Actions)

Push to `main` triggers path-filtered workflows:

- `.github/workflows/deploy-api.yml` — `gcloud run deploy eva-api --source api` (Cloud Build builds the Dockerfile)
- `.github/workflows/deploy-website.yml` — builds Astro, `firebase deploy --only hosting`

Both authenticate via **Workload Identity Federation** (no key files). Firestore/Storage rules are not deployed by CI yet; deploy manually with `firebase deploy --only firestore:rules,storage` when ready.

### One-time GCP setup (required before workflows go green)

Replace `PROJECT_ID`, `PROJECT_NUMBER`, and `GITHUB_USER/Eva`:

```sh
# 1. Enable APIs
gcloud services enable run.googleapis.com cloudbuild.googleapis.com \
  artifactregistry.googleapis.com firebasehosting.googleapis.com --project PROJECT_ID

# 2. Deploy service account
gcloud iam service-accounts create github-deployer --project PROJECT_ID

# 3. Roles
for role in roles/run.admin roles/cloudbuild.builds.editor roles/artifactregistry.writer \
            roles/firebasehosting.admin roles/storage.admin roles/iam.serviceAccountUser; do
  gcloud projects add-iam-policy-binding PROJECT_ID \
    --member "serviceAccount:github-deployer@PROJECT_ID.iam.gserviceaccount.com" --role "$role"
done

# 4. Workload Identity Federation pool + GitHub OIDC provider
gcloud iam workload-identity-pools create github --location global --project PROJECT_ID
gcloud iam workload-identity-pools providers create-oidc github-actions \
  --location global --workload-identity-pool github --project PROJECT_ID \
  --issuer-uri "https://token.actions.githubusercontent.com" \
  --attribute-mapping "google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition "assertion.repository == 'GITHUB_USER/Eva'"

# 5. Let the GitHub repo impersonate the service account
gcloud iam service-accounts add-iam-policy-binding \
  github-deployer@PROJECT_ID.iam.gserviceaccount.com --project PROJECT_ID \
  --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github/attribute.repository/GITHUB_USER/Eva"

# 6. GitHub repo variables
gh variable set GCP_PROJECT_ID --body "PROJECT_ID"
gh variable set GCP_REGION --body "us-central1"
gh variable set GCP_DEPLOY_SA --body "github-deployer@PROJECT_ID.iam.gserviceaccount.com"
gh variable set GCP_WIF_PROVIDER --body "projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github/providers/github-actions"
```

Also set the real project ID in `.firebaserc`.
