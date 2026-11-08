package com.example.party;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.networknt.schema.JsonSchema;
import com.networknt.schema.JsonSchemaFactory;
import com.networknt.schema.SpecVersion;
import com.networknt.schema.ValidationMessage;
import org.junit.jupiter.api.Test;

import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Set;
import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * Validates the committed control fixtures against the normative contracts in
 * controls-core. This is the schema gate the guide implies but does not ship.
 *
 * <p>The sibling checkout is located with CONTROLS_CORE (default
 * ../controls-core). When it is absent, the test is skipped so a standalone
 * `mvn verify` still works; `make gate` and CI always provide it.
 */
class ControlsSchemaTest {

    private static final ObjectMapper JSON = new ObjectMapper();

    @Test
    void registryMatchesContractSchema() throws Exception {
        validate("registry.json", "registry.schema.json");
    }

    @Test
    void maskPoliciesMatchContractSchema() throws Exception {
        validate("mask-policies.json", "mask-policy.schema.json");
    }

    private void validate(String document, String schemaFile) throws Exception {
        Path core = Path.of(System.getenv().getOrDefault("CONTROLS_CORE", "../controls-core"))
            .toAbsolutePath().normalize();
        Path schemaPath = core.resolve("contracts").resolve(schemaFile);
        assumeTrue(Files.exists(schemaPath),
            "controls-core contract not found at " + schemaPath
                + "; set CONTROLS_CORE or check out controls-core as a sibling");

        JsonSchemaFactory factory = JsonSchemaFactory.getInstance(SpecVersion.VersionFlag.V202012);
        JsonSchema schema;
        try (InputStream in = Files.newInputStream(schemaPath)) {
            schema = factory.getSchema(in);
        }

        JsonNode fixture = JSON.readTree(Path.of("controls", document).toFile());
        Set<ValidationMessage> errors = schema.validate(fixture);
        String detail = errors.stream()
            .map(m -> m.getInstanceLocation() + ": " + m.getMessage())
            .sorted()
            .collect(Collectors.joining("\n"));
        assertTrue(errors.isEmpty(), document + " violates " + schemaFile + ":\n" + detail);
    }
}
