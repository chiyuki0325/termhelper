package termhelper.infra

import stdx.encoding.json.*

@Test
func migrateV1ContextToCurrentFactsModel(): Unit {
    let old = JsonValue.fromStr(
        """
        {"version":1,"os":"Linux","distro":"ubuntu","package_manager":"apt","shell":"/bin/zsh","last_updated":42}
        """)

    let migrated = migrateContextJson(old).getOrThrow()
    let facts = migrated.get("facts").getOrThrow().asObject()

    @Expect(migrated.get("version").getOrThrow().asInt().getValue(), CURRENT_CONTEXT_VERSION)
    @Expect(migrated.containsKey("shell"), false)
    @Expect(facts.containsKey("distro.current"), true)
    @Expect(facts.containsKey("packageManager.apt"), true)
}

@Test
func migrateRejectsNewerUnsupportedContext(): Unit {
    let value = JsonValue.fromStr("{\"version\":999,\"facts\":{}}")

    @Expect(migrateContextJson(value).isNone())
}
