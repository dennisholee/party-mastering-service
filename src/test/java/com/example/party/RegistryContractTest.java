package com.example.party;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.yaml.snakeyaml.Yaml;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Standard-build drift check: every controlled OpenAPI operation must match the
 * committed registry, and every registry entry must have a documented
 * operation. x-controls-ignore operations must not appear in the registry.
 *
 * <p>This mirrors the gate described in SIDECAR-GUIDE.md phase 1 and phase 6,
 * but compares all bindings (action, source, attributes, freshness, masking,
 * self-description), not just the four resource annotations.
 */
class RegistryContractTest {

    private static final ObjectMapper JSON = new ObjectMapper();

    @Test
    void annotationsMatchRegistry() throws Exception {
        Map<String, Object> spec = loadSpec();
        JsonNode registry = JSON.readTree(Path.of("controls/registry.json").toFile());
        Map<String, JsonNode> endpoints = endpointsByRoute(registry);
        List<String> problems = new ArrayList<>();
        List<String> documented = new ArrayList<>();

        for (Map.Entry<String, Object> pathEntry : paths(spec).entrySet()) {
            String path = pathEntry.getKey();
            for (Map.Entry<String, Object> opEntry : operations(pathEntry.getValue()).entrySet()) {
                String method = opEntry.getKey().toUpperCase();
                Map<String, Object> op = asMap(opEntry.getValue());
                String route = method + " " + path;
                documented.add(route);

                if (Boolean.TRUE.equals(op.get("x-controls-ignore"))) {
                    if (endpoints.containsKey(route)) {
                        problems.add(route + ": x-controls-ignore route is present in the registry");
                    }
                    continue;
                }

                boolean annotated = op.containsKey("x-resource-type")
                    || op.containsKey("x-mask-policy")
                    || op.containsKey("x-resource-id");
                if (!annotated) {
                    problems.add(route + ": neither annotated nor x-controls-ignore");
                    continue;
                }

                JsonNode ep = endpoints.get(route);
                if (ep == null) {
                    problems.add(route + ": no registry entry");
                    continue;
                }
                compare(problems, route, op, ep, method);
            }
        }

        for (Map.Entry<String, JsonNode> entry : endpoints.entrySet()) {
            if (!documented.contains(entry.getKey())) {
                problems.add(entry.getKey() + ": registry entry has no documented operation ("
                    + entry.getValue().path("id").asText() + ")");
            }
        }
        assertTrue(problems.isEmpty(), String.join("\n", problems));
    }

    private void compare(List<String> problems, String route, Map<String, Object> op,
                         JsonNode ep, String method) {
        check(problems, route, "x-resource-type", op.get("x-resource-type"), ep.path("resourceType"));
        check(problems, route, "x-mask-policy", op.get("x-mask-policy"), ep.path("maskPolicy"));
        check(problems, route, "x-resource-source",
            op.getOrDefault("x-resource-source", "pip"), ep.path("resourceSource"));
        check(problems, route, "x-freshness",
            op.getOrDefault("x-freshness", "cached"), ep.path("freshness"));
        check(problems, route, "x-mask-errors",
            op.getOrDefault("x-mask-errors", true), ep.path("maskErrors"));
        check(problems, route, "x-self-describing",
            op.getOrDefault("x-self-describing", false), ep.path("selfDescribing"));

        String expectedAction = Objects.toString(op.get("x-action"), deriveAction(method));
        check(problems, route, "x-action", expectedAction, ep.path("action"));

        Object attributes = op.get("x-attributes");
        if (attributes instanceof List<?> expected) {
            JsonNode actual = ep.path("attributes");
            List<String> got = new ArrayList<>();
            actual.forEach(node -> got.add(node.asText()));
            if (!expected.equals(got)) {
                problems.add(route + ": x-attributes " + expected + " != registry " + got);
            }
        }

        int expectedStale = op.get("x-max-staleness-seconds") instanceof Number n ? n.intValue() : 0;
        if (expectedStale != ep.path("maxStalenessSeconds").asInt(0)) {
            problems.add(route + ": x-max-staleness-seconds " + expectedStale
                + " != registry " + ep.path("maxStalenessSeconds").asInt(0));
        }

        Object resourceId = op.get("x-resource-id");
        if (resourceId instanceof String id) {
            JsonNode ref = ep.path("resourceId");
            boolean body = id.startsWith("$.");
            String expectedFrom = body ? "body" : "path";
            if (!expectedFrom.equals(ref.path("from").asText())
                || !id.equals(body ? ref.path("path").asText() : ref.path("name").asText())) {
                problems.add(route + ": x-resource-id " + id + " != registry " + ref);
            }
        }
    }

    private static String deriveAction(String method) {
        return switch (method) {
            case "GET", "HEAD" -> "read";
            case "DELETE" -> "delete";
            default -> "write";
        };
    }

    private static void check(List<String> problems, String route, String key,
                              Object expected, JsonNode actual) {
        String want = String.valueOf(expected);
        String got = actual.isMissingNode() ? "<missing>" : actual.asText();
        if (!want.equals(got)) {
            problems.add(route + ": " + key + " " + want + " != registry " + got);
        }
    }

    static Map<String, Object> loadSpec() throws Exception {
        try (var in = Files.newInputStream(Path.of("openapi.yaml"))) {
            return new Yaml().load(in);
        }
    }

    static Map<String, Object> paths(Map<String, Object> spec) {
        return asMap(spec.get("paths"));
    }

    static Map<String, Object> operations(Object pathItem) {
        Map<String, Object> out = new LinkedHashMap<>();
        for (Map.Entry<String, Object> entry : asMap(pathItem).entrySet()) {
            if (entry.getValue() instanceof Map<?, ?>) {
                out.put(entry.getKey(), entry.getValue());
            }
        }
        return out;
    }

    @SuppressWarnings("unchecked")
    static Map<String, Object> asMap(Object value) {
        return (Map<String, Object>) value;
    }

    static Map<String, JsonNode> endpointsByRoute(JsonNode registry) {
        Map<String, JsonNode> out = new LinkedHashMap<>();
        for (JsonNode ep : registry.get("endpoints")) {
            out.put(ep.get("method").asText() + " " + ep.get("path").asText(), ep);
        }
        return out;
    }
}
