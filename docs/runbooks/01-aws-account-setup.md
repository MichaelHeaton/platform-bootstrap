# Runbook 01 — AWS Account Setup

**Estimated time:** ~30 minutes (new account) / ~15 minutes (existing account)

---

## 1. Overview

This runbook covers everything required to have a secure, CLI-accessible AWS account before the
platform bootstrap can run. It takes you from creating a brand-new AWS account (or securing an
existing one) through configuring local AWS CLI credentials that Terraform will use during the
one-time bootstrap procedure.

After completing this runbook you will have:

- An AWS account with MFA-protected root access
- No live root access keys
- Billing alerts at $10, $50, and $100
- A named AWS CLI profile (`platform-bootstrap`) that can authenticate as an IAM user with
  `AdministratorAccess`
- Confirmed CLI access verified with `aws sts get-caller-identity`

**This runbook is only run once per AWS account.** After bootstrap is complete the IAM user
credentials are replaced by OIDC-based GitHub Actions authentication and the user's access keys
can be deactivated or deleted.

---

## 2. Prerequisites

Before starting you need:

- An email address not already associated with an AWS account (for new account creation)
- A credit or debit card (AWS requires one even for free-tier accounts)
- A phone number for account verification (SMS or voice call)
- A virtual or hardware MFA device — Google Authenticator, Authy, 1Password TOTP, or a
  physical YubiKey
- AWS CLI v2 installed (see Section 6 if not yet installed)
- A password manager to store root credentials and access keys

---

## 3. Creating a New AWS Account

> Skip this section if you are using an existing AWS account. Go directly to Section 4.

1. Open <https://aws.amazon.com/> and click **Create an AWS Account**.
2. Enter your email address and choose an AWS account name (this is an internal label — choose
   something meaningful like `my-platform-prod`).
3. Click **Verify email address**. Check your inbox and enter the verification code.
4. Set a strong root password (16+ characters, store it in your password manager now).
5. Fill in contact information. Select **Personal** or **Business** as appropriate.
6. Enter payment information. AWS will place a small temporary authorisation hold (typically $1)
   that is reversed within a few days.
7. Verify your identity via phone (choose SMS or voice call, enter the code).
8. Choose the **Basic support plan** (free) unless you have a specific reason for a paid plan.
9. Click **Complete sign up**.
10. Wait for the confirmation email — account activation usually takes a few minutes but can take
    up to 24 hours.
11. Sign in to the AWS Management Console at <https://console.aws.amazon.com/> using your root
    email and password to confirm the account is active.

---

## 4. Root Account Security Hardening

The root account has unrestricted access to everything in your AWS account and cannot be
constrained by IAM policies. Secure it now before creating any other resources.

### 4a. Enable MFA on the Root Account

1. Sign in to the AWS Management Console as root.
2. Click your account name in the top-right corner and select **Security credentials**.
   (Direct URL: `https://console.aws.amazon.com/iam/home#/security_credentials`)
3. Expand the **Multi-factor authentication (MFA)** section.
4. Click **Assign MFA device**.
5. Enter a device name (e.g., `root-mfa`).
6. Select the device type:
   - **Authenticator app** — use this for virtual MFA (Google Authenticator, Authy, 1Password)
   - **Hardware TOTP token** — for a physical hardware key that generates TOTP codes
   - **Security key** — for a FIDO2/WebAuthn hardware key (e.g., YubiKey)
7. For **Authenticator app**: click **Show QR code**, scan it with your authenticator app, then
   enter two consecutive 6-digit codes.
8. Click **Add MFA**.
9. Confirm: the MFA device now appears in the list with a green status indicator.

**Store the MFA recovery codes or note the TOTP seed in your password manager.** Losing root MFA
access is a serious incident (see `docs/runbooks/03-disaster-recovery.md`).

### 4b. Verify No Root Access Keys Exist

Still on the Security credentials page:

1. Scroll to the **Access keys** section.
2. If any access keys are listed, **delete them immediately** — root access keys are a critical
   security risk with no legitimate operational use.
3. Do not create root access keys. If AWS prompts you to create them at any point, decline.

### 4c. Set Up Billing Alerts

**Enable Cost Explorer:**

1. Navigate to **Billing and Cost Management** → **Cost Explorer**
   (or: <https://console.aws.amazon.com/cost-management/home>).
2. Click **Enable Cost Explorer** if it is not already enabled. Activation takes up to 24 hours.

**Create billing alarms in CloudWatch:**

1. Navigate to **CloudWatch** → **Alarms** → **Billing**.
   (Direct URL: `https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#alarmsV2:`)
   > Note: Billing metrics are only available in `us-east-1` regardless of your chosen region.
2. Click **Create alarm**.
3. Click **Select metric** → **Billing** → **Total Estimated Charge** → select
   `EstimatedCharges` with `Currency: USD` → click **Select metric**.
4. Set the threshold:
   - Threshold type: **Static**
   - Condition: **Greater than**
   - Value: `10`
5. Click **Next**. Under **Notification**, create a new SNS topic:
   - Topic name: `billing-alerts`
   - Email endpoint: your email address
6. Click **Create topic** then **Next**.
7. Alarm name: `billing-alert-10usd`
8. Click **Next** → **Create alarm**.
9. **Repeat steps 2–8** for thresholds of `50` (alarm name: `billing-alert-50usd`) and `100`
   (alarm name: `billing-alert-100usd`).
10. Check your email and confirm the SNS subscription for each alarm. Alarms will not fire until
    the subscription is confirmed.

### 4d. Lock the Root Account

The root account should never be used for day-to-day operations.

1. Ensure the root password and MFA recovery information are stored securely in your password
   manager under an entry named something like `AWS root — <account-name>`.
2. Sign out of the AWS console.
3. From this point forward, use only the IAM user created in Section 5. Return to the root
   account only for tasks that explicitly require it (e.g., closing the account, changing
   the account email address, or recovering from a complete IAM lockout).

---

## 5. Creating an Initial IAM User for Bootstrapping

The bootstrap Terraform run needs AWS credentials. Two options are described. Choose one.

### Option A — IAM User with AdministratorAccess (recommended for personal accounts)

1. Sign in to the AWS console as root.
2. Navigate to **IAM** → **Users** → **Create user**.
3. User name: `platform-bootstrap-admin`
4. Do **not** enable console access (this user is for CLI use only).
5. Click **Next**.
6. Select **Attach policies directly**.
7. Search for and select **AdministratorAccess**.
8. Click **Next** → **Create user**.
9. Click the user name to open the user detail page.
10. Click the **Security credentials** tab.
11. Click **Create access key**.
12. Select **Command Line Interface (CLI)** as the use case.
13. Acknowledge the recommendation and click **Next**.
14. Description tag: `platform-bootstrap initial setup`
15. Click **Create access key**.
16. **Copy both the Access Key ID and Secret Access Key now** — the secret is only shown once.
    Store both values in your password manager.
17. Click **Done**.

> After bootstrap is complete and OIDC is verified, return to this user, deactivate the access
> key, and optionally delete the user. The OIDC role takes over from that point.

### Option B — IAM Role with AssumeRole (for AWS Organizations setups)

This option is for environments where a management account grants cross-account access. It
requires an existing trusted account and is more complex to set up initially.

1. In the management account, create an IAM role in the target account that trusts the
   management account's IAM identity (user or role).
2. Attach `AdministratorAccess` to the target role.
3. Configure the AWS CLI to assume this role using a `role_arn` and `source_profile` in
   `~/.aws/config`.

See [AWS documentation on cross-account roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/tutorial_cross-account-with-roles.html)
for full details. Multi-account setup via AWS Organizations is deferred pending scale review —
see ADR-006 in this repository for context.

---

## 6. AWS CLI Configuration

### Installing AWS CLI v2

**macOS (Homebrew):**

```bash
brew install awscli
```

**Linux (apt):**

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

**All platforms — verify:**

```bash
aws --version
# Expected: aws-cli/2.x.x Python/3.x.x ...
```

Full installation documentation: <https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html>

### Configuring the Named Profile

Run the following command to configure a named profile called `platform-bootstrap`:

```bash
aws configure --profile platform-bootstrap
```

You will be prompted for four values. Enter them as follows:

```
AWS Access Key ID [None]: <paste Access Key ID from Section 5>
AWS Secret Access Key [None]: <paste Secret Access Key from Section 5>
Default region name [None]: us-east-1       # or your chosen region
Default output format [None]: json
```

This writes to `~/.aws/credentials` and `~/.aws/config`. The credentials file should now
contain an entry similar to:

```ini
[profile platform-bootstrap]
region = us-east-1
output = json
```

### Testing the Profile

```bash
aws sts get-caller-identity --profile platform-bootstrap
```

Expected output (account ID and ARN will reflect your account):

```json
{
    "UserId": "AIDAEXAMPLEEXAMPLEEX",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/platform-bootstrap-admin"
}
```

Set the profile for the remainder of your terminal session to avoid passing `--profile` on
every command:

```bash
export AWS_PROFILE=platform-bootstrap
```

Verify without the flag:

```bash
aws sts get-caller-identity
# Same output as above
```

---

## 7. Verification Checklist

Run through each item before proceeding to the bootstrap runbook. All items must pass.

**AWS CLI access:**

```bash
# Must return your account ID, not an error
aws sts get-caller-identity --profile platform-bootstrap

# Must list S3 buckets without error (empty list is fine for a new account)
aws s3 ls --profile platform-bootstrap
```

**Root account hardening — verify in the AWS console:**

- [ ] Root MFA is listed as **Active** on the Security credentials page
- [ ] No root access keys exist on the Security credentials page
- [ ] Three billing alarms (`billing-alert-10usd`, `billing-alert-50usd`,
      `billing-alert-100usd`) are listed as **OK** or **Insufficient data** in CloudWatch
      Billing Alarms
- [ ] SNS email subscriptions have been confirmed (check your inbox)

**Account ID noted:**

```bash
# Record this value — you will need it in runbook 02
aws sts get-caller-identity --profile platform-bootstrap \
  --query Account --output text
```

---

## 8. AWS Organizations (Future State Note)

Multi-account management via AWS Organizations — including service control policies,
consolidated billing, and cross-account trust — is deferred pending scale review.

See **ADR-006** in this repository for the decision record and the conditions under which
Organizations setup will be revisited. Until that ADR is revisited, this platform operates
as a single-account setup.

---

## 9. Next Steps

This runbook is complete.

Proceed to: **`docs/runbooks/02-bootstrap.md`**
