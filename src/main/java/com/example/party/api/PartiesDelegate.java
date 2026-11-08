package com.example.party.api;

import com.example.party.model.Party;
import com.example.party.model.PartyMergeRequest;
import com.example.party.model.PartyMergeResult;
import com.example.party.model.PartyUpdateRequest;
import com.example.party.service.PartyMasteringService;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Service;

import java.util.List;

/**
 * Delegate that adapts the generated OpenAPI API to the mastering service.
 *
 * <p>Responses intentionally contain raw golden-record values. Masking is the
 * sidecar's job; the application never ships half-masked data.
 */
@Service
public class PartiesDelegate implements PartiesApiDelegate {

    private final PartyMasteringService service;

    public PartiesDelegate(PartyMasteringService service) {
        this.service = service;
    }

    @Override
    public ResponseEntity<Party> getParty(String partyId) {
        return ResponseEntity.ok(service.get(partyId));
    }

    @Override
    public ResponseEntity<Party> updateParty(String partyId, PartyUpdateRequest partyUpdateRequest) {
        return ResponseEntity.ok(service.update(partyId, partyUpdateRequest));
    }

    @Override
    public ResponseEntity<PartyMergeResult> mergeParty(String partyId, PartyMergeRequest partyMergeRequest) {
        return ResponseEntity.status(HttpStatus.CREATED)
            .body(service.merge(partyId, partyMergeRequest));
    }

    @Override
    public ResponseEntity<List<Party>> searchParties(String query, Integer limit) {
        return ResponseEntity.ok(service.search(query, limit));
    }
}
