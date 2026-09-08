# Essentials

Concise notes on the technologies, techniques and protocols the cases use — enough to explain a concept or its mechanism from cold, and no more. Entries are added on demand with `/kb`.

Each entry is a `###` term heading, the topic tags it can be found by, and one sentence saying what it is in essence, followed by an expandable block holding **How it works**, **Boundary** — what it is not and what it is confused with — an optional **Alternatives** comparison, and an **Example**. Categories are `##` headings; terms are alphabetical within their category.

**Tags in use:** `identity-provisioning` — extend this list rather than coining a synonym for a tag already on it. Tags are single tokens, hyphenated where a bare word would mean something else in another part of this file.

## Protocols

### SCIM
`identity-provisioning`

A standard REST API one system uses to create, update and delete user accounts inside another — the identity provider pushes the changes, and the application only implements the endpoints.

<details><summary>Details</summary>

**How it works:** A fixed JSON schema for `User` and `Group` resources, served at `/Users` and `/Groups` over ordinary HTTP verbs — `POST` to create, `PATCH` to change one attribute, `DELETE` to deprovision. The identity provider is the client and drives every change; the application is the server and only reacts. Because the schema is fixed, one connector works against any compliant application.

**Boundary:** Provisioning only — it cannot authenticate anyone or carry a sign-in. That is SAML or OIDC's job, and the two run together: OIDC logs the user in, SCIM makes sure the account existed to be logged into and is gone the day they leave.

**Alternatives:**
- **LDAP directory sync** — the application pulls the directory on a schedule instead of being pushed to. Simpler to run, slower to reflect a leaver.
- **Just-in-time provisioning** from SAML or OIDC claims — creates the account at first sign-in and needs no extra API, but nothing ever deprovisions.

**Example:** HR marks an employee as a leaver. The identity provider sends `PATCH /Users/<id>` with `active: false` to every connected application, and access ends everywhere without an administrator touching any of them.

</details>
