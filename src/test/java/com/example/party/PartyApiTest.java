package com.example.party;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Application-level behaviour, without the sidecar. These tests prove the
 * service returns raw golden-record values and leaves entitlement, masking and
 * DQ to the controls plane.
 */
@SpringBootTest
@AutoConfigureMockMvc
class PartyApiTest {

    @Autowired
    private MockMvc mvc;

    @Test
    void applicationReturnsRawGoldenRecord() throws Exception {
        mvc.perform(get("/parties/PTY-1001"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.partyId").value("PTY-1001"))
            .andExpect(jsonPath("$.partyType").value("INDIVIDUAL"))
            .andExpect(jsonPath("$.legalName.firstName").value("Jane"))
            .andExpect(jsonPath("$.ssn").value("111-22-3333"))
            .andExpect(jsonPath("$.taxId").value("TIN-99-8877665"))
            .andExpect(jsonPath("$.dateOfBirth").value("1984-07-12"))
            .andExpect(jsonPath("$.contactPoints.email.value").value("jane.doe@example.com"))
            .andExpect(jsonPath("$.documents[0].number").value("X1234567"))
            .andExpect(jsonPath("$.version").value(1));
    }

    @Test
    void unknownPartyIs404() throws Exception {
        mvc.perform(get("/parties/PTY-9999"))
            .andExpect(status().isNotFound())
            .andExpect(jsonPath("$.error").value("party_not_found"));
    }

    @Test
    void internalSearchStillExistsOnTheApplication() throws Exception {
        mvc.perform(get("/parties").param("query", "Jane"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$[0].partyId").value("PTY-1001"))
            .andExpect(jsonPath("$[0].ssn").value("111-22-3333"));
    }

    @Test
    void missingRequiredFieldIsApplicationValidation() throws Exception {
        String body = """
            {
              "dateOfBirth": "1984-07-12",
              "contactPoints": {
                "email": {"value": "jane.doe@example.com"},
                "phone": {"value": "+1-415-555-0142"}
              },
              "segment": "PREMIER",
              "changeReason": "CUSTOMER_REQUEST",
              "version": 1
            }
            """;
        mvc.perform(put("/parties/PTY-1001")
                .contentType(MediaType.APPLICATION_JSON)
                .content(body))
            .andExpect(status().isBadRequest())
            .andExpect(jsonPath("$.error").value("validation_failed"));
    }

    @Test
    void staleVersionIsConflict() throws Exception {
        String body = """
            {
              "legalName": {"firstName": "Jane", "lastName": "Doe"},
              "dateOfBirth": "1984-07-12",
              "contactPoints": {
                "email": {"value": "jane.doe@example.com"},
                "phone": {"value": "+1-415-555-0142"}
              },
              "segment": "PREMIER",
              "changeReason": "CUSTOMER_REQUEST",
              "version": 99
            }
            """;
        mvc.perform(put("/parties/PTY-1001")
                .contentType(MediaType.APPLICATION_JSON)
                .content(body))
            .andExpect(status().isConflict())
            .andExpect(jsonPath("$.error").value("version_conflict"));
    }

    @Test
    void mergeSourceMayNotEqualTarget() throws Exception {
        mvc.perform(post("/parties/PTY-1001/merges")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"sourcePartyId\":\"PTY-1001\",\"reason\":\"DUPLICATE\"}"))
            .andExpect(status().isBadRequest())
            .andExpect(jsonPath("$.error").value("source_equals_target"));
    }

    @Test
    void mergeUnknownSourceIs404() throws Exception {
        mvc.perform(post("/parties/PTY-1001/merges")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"sourcePartyId\":\"PTY-9999\",\"reason\":\"DUPLICATE\"}"))
            .andExpect(status().isNotFound())
            .andExpect(jsonPath("$.error").value("source_party_not_found"));
    }
}
