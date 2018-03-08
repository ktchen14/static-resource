# Static Resource

A resource that creates static files from the source configuration. Used to pass
information that shouldn't go in `params` to tasks.

To use this resource in a pipeline ensure that the `resource_types` section has
this information:

```yaml
resource_types:
- name: static
  type: docker-image
  source: { repository: vaneci/static-resource }
```

## Source Configuration

The source configuration is a mapping of arbitrary names to values. For example:

```yaml
source: 
  message: |
    This is a very long message that I want to pass to a task ...
  hint: This is a similarly verbose hint that I want to send
```

Any data that should be hidden from the Concourse UI when this resource is used
should be specified like:

```yaml
source: 
  username: my-username
  password:
    public: "<<hidden>>"
    secret: my-password
```

## Behavior

### `check`: Return an identifier for the source configuration

The source configuration is read and a stable base 16 encoded SHA1 hash is
derived; the hash remains constant so long as the source configuration remains
semantically unchanged.

### `in`: Output each item in the source configuration

Each item in the source configuration will become a file in the resource's
output directory. For example this configuration:

```yaml
resources:
- name: static-secret
  type: static
  source: 
    username: my-username
    password:
      public: "<<hidden>>"
      secret: my-password
```

When this step is executed:

```yaml
- get: static-secret
```

Will produce the output directory where the content of each file is in `()`:

```
static-secret
├── username (my-username)
└── password (my-password)
```

And the written data will be reproduced in the Concourse UI with `my-password`
replaced by `<<hidden>>`.
