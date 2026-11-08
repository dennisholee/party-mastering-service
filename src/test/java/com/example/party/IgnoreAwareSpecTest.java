package com.example.party;

import org.junit.jupiter.api.Test;
import org.yaml.snakeyaml.DumperOptions;
import org.yaml.snakeyaml.Yaml;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Produces the spec used by {@code openapi-diff}.
 *
 * <p>Why this exists: SIDECAR-GUIDE.md documents {@code x-controls-ignore} as
 * "omit a route from the generated registry", and {@code openapi-registry}
 * honours it. The {@code openapi-diff} gate in controls-core v0.38.3 does not
 * skip ignored operations, so running it on the raw contract reports the
 * deliberately-excluded route as a missing registry entry. Rather than
 * hand-editing the registry (an anti-pattern), the build writes an
 * ignore-filtered copy of the contract to {@code target/controlled-openapi.yaml}
 * and runs the diff against that. See docs/SIDECAR-GUIDE-ADDENDUM.md, gap G1.
 *
 * <p>When openapi-diff learns to skip x-controls-ignore, delete this test and
 * point the Makefile gate at openapi.yaml again.
 */
class IgnoreAwareSpecTest {

    @Test
    void writesIgnoreFilteredSpecForOpenApiDiff() throws Exception {
        Map<String, Object> spec = RegistryContractTest.loadSpec();
        List<String> removed = new ArrayList<>();

        for (Map.Entry<String, Object> pathEntry : RegistryContractTest.paths(spec).entrySet()) {
            Map<String, Object> pathItem = RegistryContractTest.asMap(pathEntry.getValue());
            List<String> ignoredMethods = new ArrayList<>();
            for (Map.Entry<String, Object> opEntry : RegistryContractTest.operations(pathItem).entrySet()) {
                Map<String, Object> op = RegistryContractTest.asMap(opEntry.getValue());
                if (Boolean.TRUE.equals(op.get("x-controls-ignore"))) {
                    ignoredMethods.add(opEntry.getKey());
                    removed.add(opEntry.getKey().toUpperCase() + " " + pathEntry.getKey());
                }
            }
            ignoredMethods.forEach(pathItem::remove);
        }

        assertFalse(removed.isEmpty(),
            "expected at least one x-controls-ignore operation to exercise the workaround");

        Path out = Path.of("target", "controlled-openapi.yaml");
        Files.createDirectories(out.getParent());
        DumperOptions options = new DumperOptions();
        options.setDefaultFlowStyle(DumperOptions.FlowStyle.BLOCK);
        try (var writer = Files.newBufferedWriter(out)) {
            new Yaml(options).dump(spec, writer);
        }
        assertTrue(Files.size(out) > 0, "filtered OpenAPI document is empty");
    }
}
