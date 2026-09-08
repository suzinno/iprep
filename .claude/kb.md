# Essentials

Concise notes on the technologies, techniques and protocols the cases use — enough to explain a concept or its mechanism from cold, and no more. Entries are added on demand with `/kb`.

Each entry is a `###` term heading, the topic tags it can be found by, and one sentence saying what it is in essence, followed by an expandable block holding **How it works**, **Boundary** — what it is not and what it is confused with — an optional **Alternatives** comparison, and an **Example**. Categories are `##` headings; terms are alphabetical within their category.

**Tags in use:** `directory` · `identity-provisioning` · `iot` · `messaging` — extend this list rather than coining a synonym for a tag already on it. Tags are single tokens, hyphenated where a bare word would mean something else in another part of this file.

## Protocols

### AMQP
`messaging`

A binary protocol for passing messages between services through a broker, with delivery confirmed rather than assumed. The sender hands a message to the broker, which holds it in a queue until a consumer acknowledges having processed it.

<details><summary>Details</summary>

**How it works:** In the 0-9-1 model, a publisher never names a queue. It publishes to an *exchange* with a *routing key*, and *bindings* declared on the exchange decide which queues receive a copy — one, several, or none. A consumer takes messages from a queue and returns an *ack*; an unacknowledged message whose consumer dies is redelivered, and a rejected one can be dropped, requeued or sent to a dead-letter queue. Prefetch limits how many a consumer may hold unacknowledged at once, which is what keeps a slow worker from being buried.

**Boundary:** Two protocols share the name, and they are not interchangeable — a 1.0 client cannot talk to a 0-9-1 broker. The exchange and binding model above is 0-9-1, which is what RabbitMQ speaks; AMQP 1.0 is a different, lower-level link protocol used by Azure Service Bus and others, and leaves routing to the broker's own concepts. It is also a protocol, not a product: RabbitMQ is one implementation, and much of what people call AMQP behaviour is RabbitMQ's. Like a queue and unlike a log, an acknowledged message is gone — which is the real contrast with Kafka, a system rather than a protocol, whose consumers keep a position in a log they can rewind.

**Alternatives:**
- **MQTT** — topic matching instead of exchanges and bindings, and far lighter on constrained clients. The right trade for telemetry from many devices, the wrong one for work queues that must not lose a job.
- **STOMP** — a text-based frame protocol that any language can speak in a few lines. Much simpler to implement and debug, with none of the routing or delivery machinery.

**Example:** An order service publishes to the `orders` exchange with routing key `order.placed`. A `billing` queue and an `analytics` queue are both bound to that key, so each gets a copy; the billing worker acks only after the payment row is committed, so a crash mid-charge returns the message to the queue rather than losing it.

</details>

### LDAP
`directory`

A protocol for reading and writing entries in a hierarchical directory. A client connects to a directory server, searches under a branch of the tree, and can also hand the server a name and password for it to verify.

<details><summary>Details</summary>

**How it works:** Entries sit in a tree, each identified by a *distinguished name* built from its path — `cn=jsmith,ou=people,dc=example,dc=com` — and each holding attributes whose permitted names and types come from a schema. A client authenticates with a *bind*: a simple bind sends a distinguished name and a password, and the server answers whether it accepted them. A bind carrying an empty password is an *unauthenticated* bind that many servers accept, so an application must reject empty passwords itself rather than read any success as proof. Reads use a *search*, given a *base* to start from, a scope saying how deep to go, and a filter such as `(&(objectClass=person)(department=cardiology))`. Writes exist but are single-entry operations; the protocol runs over TCP, wrapped in TLS in any deployment that matters.

**Boundary:** A protocol, not a product. Active Directory is a directory server that speaks it alongside Kerberos and much else, and OpenLDAP is another; most claims about "LDAP behaviour" are really claims about one of them. An accepted bind says the server accepted those credentials at that instant and nothing more — no token, no session, no expiry — so an application still has to issue its own session afterwards. And it is not a relational database: entries are read far more often than written, there are no joins and no transaction spanning two entries.

**Alternatives:** OIDC, where the application redirects to an identity provider instead of taking the password itself and binding with it. Safer, since the application never sees the credential, and it carries a session where a bind does not — but it gives no way to query the tree, so anything that needs to list a department's members still wants a directory.

**Example:** An intranet application authenticates someone by binding as `cn=jsmith,ou=people,dc=example,dc=com` with the password they typed, having refused it first if it was empty; an accepted bind then means the credentials were valid. It then searches from base `ou=groups,dc=example,dc=com` with the filter `(member=cn=jsmith,ou=people,dc=example,dc=com)` to learn which groups they belong to.

</details>

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
