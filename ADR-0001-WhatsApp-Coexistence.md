# ADR-0001: WhatsApp Migration to Meta Coexistence

## Status
Proposed

## Context & Problem Statement
The current integration with WhatsApp relies on a manual setup for the Cloud API. This manual process is error-prone, difficult to scale, and lacks the flexibility required for our growing system needs. Additionally, managing secrets and enabling new features safely in production has become increasingly complex under the legacy architecture. We need a robust, scalable, and automated approach to manage WhatsApp communications.

## Decisions

### Why Cloud API manual setup was replaced
The legacy approach of manually configuring the WhatsApp Cloud API was replaced because it hindered automation and scalability. Manual configurations lead to environment inconsistencies, make disaster recovery difficult, and slow down the onboarding of new environments or developers. Transitioning to a programmatic and automated setup reduces human error and improves deployment velocity.

### Why Meta Coexistence was chosen
Meta Coexistence was chosen as the architectural pattern to allow both legacy and new systems to operate simultaneously during the migration. This pattern minimizes downtime and risk by providing a safe environment to test the new integration alongside the old one. It enables a gradual transition where traffic can be routed dynamically, ensuring stability and continuous availability of WhatsApp services.

### Why Secret Manager is used
Google Cloud Secret Manager is implemented to handle all sensitive credentials, including API keys and tokens. Hardcoding or manually injecting secrets is a security risk. Using Secret Manager ensures that secrets are encrypted at rest, access is strictly controlled via IAM, and secrets can be rotated seamlessly without requiring code deployments.

### Why Feature Flags were introduced
Feature flags are introduced to decouple deployment from release. By wrapping the new Meta Coexistence logic in feature flags, we can safely deploy the code to production without immediately affecting all users. This allows us to perform targeted rollouts, run A/B tests, and quickly disable the new feature if any issues arise, without needing a full rollback of the deployment.

## Migration Phases

The migration is structured into the following 8 phases (0-7):

*   **Phase 0: Preparation & Infrastructure:** Set up Secret Manager, define feature flags, and provision necessary cloud resources.
*   **Phase 1: Secret Migration:** Migrate all existing WhatsApp API credentials to Secret Manager and update the legacy system to fetch from there.
*   **Phase 2: Core Coexistence Implementation:** Develop the new Meta Coexistence integration alongside the legacy code.
*   **Phase 3: Internal Testing (Alpha):** Enable the new integration via feature flags for internal test accounts only.
*   **Phase 4: Shadow Mode (Beta):** Route a small percentage (e.g., 5%) of live traffic to the new system while monitoring closely.
*   **Phase 5: Gradual Rollout:** Incrementally increase the traffic routed to the new system (25%, 50%, 75%) using feature flags.
*   **Phase 6: Full Cutover:** Route 100% of traffic to the new Meta Coexistence integration.
*   **Phase 7: Cleanup:** Remove legacy code, redundant configurations, and outdated feature flags.

## Rollback Strategy
If critical issues are detected during any phase before Phase 7, the rollback strategy relies on feature flags. By simply toggling the feature flag off, traffic will immediately revert to the legacy Cloud API manual setup. This action is nearly instantaneous and does not require a code redeployment.

## Production Rollout Strategy
The production rollout will follow the phased approach (Phases 3-6). We will monitor key metrics (error rates, message delivery latency, webhook success rates) at each step. Progression to the next traffic tier will only occur after a predefined observation period without anomalies.

## Legacy Retirement Criteria
The legacy Cloud API manual setup code will be retired (Phase 7) only when:
1. The new Meta Coexistence integration has handled 100% of production traffic for an extended period without major incidents.
2. All required features are verified to be fully functional in the new system.
3. No fallback events to the legacy system have occurred.

## Future Improvements
*   Implement automated end-to-end testing for WhatsApp message flows.
*   Explore advanced analytics on messaging delivery and engagement using the new architecture.
*   Automate the rotation of secrets stored in Secret Manager.
