mapping.json

```json
[
  {
    "local": [
      {
        "user": {
          "name": "{0}",
          "domain": {
            "name": "Default"
          },
          "type": "ephemeral"
        },
        "group": {
          "id": "1b2083fcdcf5419397ba2e4091da0b62"
        }
      }
    ],
    "remote": [
      {
        "type": "HTTP_OIDC_EMAIL"
      }
    ]
  }
]
```

```bash
openstack mapping set --rules mapping.json zitadel
openstack identity provider set --remote-id https://rpcu-gabeck.eu1.zitadel.cloud zitadel
openstack federation protocol create --identity-provider zitadel --mapping zitadel openid
```
