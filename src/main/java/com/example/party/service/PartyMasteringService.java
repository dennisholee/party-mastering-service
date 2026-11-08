package com.example.party.service;

import com.example.party.model.Party;
import com.example.party.model.PartyMergeRequest;
import com.example.party.model.PartyMergeResult;
import com.example.party.model.PartyUpdateRequest;
import com.example.party.repository.PartyRepository;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.web.server.ResponseStatusException;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Party mastering business logic.
 *
 * <p>This class deliberately knows nothing about entitlements, masking or DQ.
 * Those are data-plane controls enforced by the sidecar before requests arrive.
 * Keeping the concerns apart is what lets the service team own the contract and
 * the delivery team own policy.
 */
@Service
public class PartyMasteringService {

    private final PartyRepository repository;
    private final AtomicLong mergeSequence = new AtomicLong(90000);

    public PartyMasteringService(PartyRepository repository) {
        this.repository = repository;
    }

    public Party get(String partyId) {
        return repository.find(partyId)
            .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND, "party_not_found"));
    }

    /**
     * Full replacement of the customer-maintained attributes. Identifiers
     * ({@code ssn}, {@code taxId}, documents), ownership and status are not
     * writable through this journey; the sidecar rejects cleartext identifiers
     * and the service preserves the authoritative values.
     */
    public synchronized Party update(String partyId, PartyUpdateRequest request) {
        Party existing = get(partyId);
        if (!existing.getVersion().equals(request.getVersion())) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "version_conflict");
        }

        existing.setLegalName(request.getLegalName());
        existing.setDateOfBirth(request.getDateOfBirth());
        existing.setContactPoints(request.getContactPoints());
        existing.setSegment(Party.SegmentEnum.fromValue(request.getSegment().getValue()));
        if (request.getAddresses() != null && !request.getAddresses().isEmpty()) {
            existing.setAddresses(request.getAddresses());
        }
        if (request.getDocuments() != null && !request.getDocuments().isEmpty()) {
            existing.setDocuments(request.getDocuments());
        }
        existing.setVersion(existing.getVersion() + 1);
        existing.setUpdatedAt(OffsetDateTime.now());
        return repository.save(existing);
    }

    public synchronized PartyMergeResult merge(String targetPartyId, PartyMergeRequest request) {
        Party target = get(targetPartyId);
        if (target.getStatus() == Party.StatusEnum.CLOSED) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "target_party_closed");
        }
        if (targetPartyId.equals(request.getSourcePartyId())) {
            // Cross-field rules are not expressible in the DQ contract today;
            // the application owns this semantic check.
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "source_equals_target");
        }
        Party source = repository.find(request.getSourcePartyId())
            .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND, "source_party_not_found"));
        if (source.getStatus() == Party.StatusEnum.CLOSED) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "source_party_closed");
        }

        source.setStatus(Party.StatusEnum.CLOSED);
        source.setVersion(source.getVersion() + 1);
        source.setUpdatedAt(OffsetDateTime.now());
        repository.save(source);

        target.setVersion(target.getVersion() + 1);
        target.setUpdatedAt(OffsetDateTime.now());
        repository.save(target);

        return new PartyMergeResult()
            .mergeId("MRG-" + mergeSequence.incrementAndGet())
            .partyId(targetPartyId)
            .mergedFromPartyId(source.getPartyId())
            .status(PartyMergeResult.StatusEnum.COMPLETED)
            .mergedAt(OffsetDateTime.now());
    }

    public List<Party> search(String query, Integer limit) {
        int effective = limit == null ? 20 : limit;
        if (effective < 1 || effective > 50) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "invalid_limit");
        }
        return repository.search(query, effective);
    }
}
