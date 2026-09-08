# Essentials

Concise notes on the technologies, techniques and protocols the cases use — enough to explain a concept or its mechanism from cold, and no more. Entries are added on demand with `/kb`.

Each entry is a `###` term heading, the topic tags it can be found by, and one sentence saying what it is in essence, followed by an expandable block holding **How it works**, **Boundary** — what it is not and what it is confused with — an optional **Alternatives** comparison, and an **Example**. Categories are `##` headings; terms are alphabetical within their category.

**Tags in use:** `identity-provisioning` · `iot` · `messaging` — extend this list rather than coining a synonym for a tag already on it. Tags are single tokens, hyphenated where a bare word would mean something else in another part of this file.

## Protocols

### MQTT
`messaging` `iot`

A lightweight publish and subscribe protocol for devices on slow or unreliable networks. Clients never address each other — they publish to a named topic on a broker, which fans each message out to whoever subscribed.

<details><summary>Details</summary>

**How it works:** A client opens one long-lived TCP connection with a `CONNECT` packet, then publishes to slash-separated topic strings such as `sensors/aisle-4/temp`. Subscribers match those with wildcards — `+` for one level, `#` for the rest of the tree — so `sensors/+/temp` catches every aisle. The broker owns the subscription table and does all the routing; neither side knows the other exists. Delivery is negotiated per message: QoS 0 at most once, 1 at least once, 2 exactly once. A client can also register a *last will* that the broker publishes on its behalf if the connection drops.

**Boundary:** Not a queue and not a log: topic matching is the only routing, and while retained messages give a last known value and persistent sessions replay what was missed, nothing rewinds history. Kafka is therefore the usual complement rather than a rival — a connector bridges device topics into a replayable log. MQTT 5's shared subscriptions are the closest it comes to a consumer group.

**Alternatives:**
- **CoAP** — the same job over UDP with a REST-shaped request model. Lighter still and works without a broker, but has no equivalent of a persistent session.
- **AMQP** — durable queues, exchanges, per-message acknowledgement. Far richer broker semantics, at a cost on the wire and in the client that MQTT exists to avoid.
- **Plain HTTPS requests** — no broker to operate and no new protocol, but each device pays a full connection per reading and nothing is pushed back to it.

**Example:** A cold store's sensors each publish to `sensors/aisle-4/freezer-2/temp` every thirty seconds. An alerting service subscribes to `sensors/+/+/temp` and sees every reading; adding a freezer needs no change to it.

</details>

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
