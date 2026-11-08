package com.example.party.repository;

import com.example.party.model.Address;
import com.example.party.model.Consent;
import com.example.party.model.ContactPoints;
import com.example.party.model.EmailContact;
import com.example.party.model.IdentityDocument;
import com.example.party.model.LegalName;
import com.example.party.model.Party;
import com.example.party.model.PhoneContact;
import org.springframework.stereotype.Repository;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;

/**
 * In-memory golden-record store for the demo. A production mastering service
 * would use the mastering database and keep the PIP read model in sync through
 * its normal publication path.
 */
@Repository
public class PartyRepository {

    private final ConcurrentMap<String, Party> parties = new ConcurrentHashMap<>();

    public PartyRepository() {
        seed();
    }

    public Optional<Party> find(String partyId) {
        return Optional.ofNullable(parties.get(partyId));
    }

    public Party save(Party party) {
        parties.put(party.getPartyId(), party);
        return party;
    }

    public List<Party> search(String query, int limit) {
        String needle = query == null ? "" : query.trim().toLowerCase(Locale.ROOT);
        return parties.values().stream()
            .filter(p -> needle.isEmpty()
                || p.getPartyId().toLowerCase(Locale.ROOT).contains(needle)
                || (p.getLegalName().getFirstName() + " " + p.getLegalName().getLastName())
                    .toLowerCase(Locale.ROOT).contains(needle))
            .sorted(Comparator.comparing(Party::getPartyId))
            .limit(limit)
            .toList();
    }

    private void seed() {
        Party jane = new Party()
            .partyId("PTY-1001")
            .partyType(Party.PartyTypeEnum.INDIVIDUAL)
            .legalName(new LegalName().firstName("Jane").middleName("Q").lastName("Doe"))
            .dateOfBirth(LocalDate.of(1984, 7, 12))
            .ssn("111-22-3333")
            .taxId("TIN-99-8877665")
            .contactPoints(new ContactPoints()
                .email(new EmailContact().value("jane.doe@example.com").verified(true))
                .phone(new PhoneContact().value("+1-415-555-0142").verified(true)))
            .addresses(new ArrayList<>(List.of(new Address()
                .type(Address.TypeEnum.HOME)
                .line1("1 Market St")
                .line2("Apt 9")
                .city("San Francisco")
                .administrativeArea("CA")
                .postalCode("94105")
                .country("US"))))
            .documents(new ArrayList<>(List.of(new IdentityDocument()
                .type(IdentityDocument.TypeEnum.PASSPORT)
                .number("X1234567")
                .issuingCountry("US"))))
            .segment(Party.SegmentEnum.PREMIER)
            .status(Party.StatusEnum.ACTIVE)
            .riskRating(Party.RiskRatingEnum.LOW)
            .ownerId("cust-1001")
            .relationshipManagerId("rm-77")
            .region("US")
            .version(1)
            .updatedAt(OffsetDateTime.parse("2026-11-01T09:15:00Z"))
            .sourceSystems(new ArrayList<>(List.of("CORE", "CRM")))
            .consents(new ArrayList<>(List.of(
                new Consent().purpose(Consent.PurposeEnum.MARKETING).granted(false).reference("CONSENT-77"),
                new Consent().purpose(Consent.PurposeEnum.ANALYTICS).granted(true).reference("CONSENT-78"))));

        Party lars = new Party()
            .partyId("PTY-2002")
            .partyType(Party.PartyTypeEnum.INDIVIDUAL)
            .legalName(new LegalName().firstName("Lars").lastName("Nielsen"))
            .dateOfBirth(LocalDate.of(1979, 2, 3))
            .ssn("222-33-4444")
            .taxId("TIN-EU-123456")
            .contactPoints(new ContactPoints()
                .email(new EmailContact().value("lars.nielsen@example.dk").verified(true))
                .phone(new PhoneContact().value("+45-20-12-34-56").verified(false)))
            .addresses(new ArrayList<>(List.of(new Address()
                .type(Address.TypeEnum.WORK)
                .line1("Strandvejen 12")
                .city("Copenhagen")
                .administrativeArea("Hovedstaden")
                .postalCode("2100")
                .country("DK"))))
            .documents(new ArrayList<>(List.of(new IdentityDocument()
                .type(IdentityDocument.TypeEnum.PASSPORT)
                .number("Y7654321")
                .issuingCountry("DK"))))
            .segment(Party.SegmentEnum.RETAIL)
            .status(Party.StatusEnum.BLOCKED)
            .riskRating(Party.RiskRatingEnum.MEDIUM)
            .ownerId("cust-2002")
            .relationshipManagerId("rm-88")
            .region("EU")
            .version(1)
            .updatedAt(OffsetDateTime.parse("2026-10-18T16:40:00Z"))
            .sourceSystems(new ArrayList<>(List.of("CORE")))
            .consents(new ArrayList<>());

        Party mei = new Party()
            .partyId("PTY-3003")
            .partyType(Party.PartyTypeEnum.INDIVIDUAL)
            .legalName(new LegalName().firstName("Mei").lastName("Chen"))
            .dateOfBirth(LocalDate.of(1990, 11, 23))
            .ssn("333-44-5555")
            .taxId("TIN-AP-778899")
            .contactPoints(new ContactPoints()
                .email(new EmailContact().value("mei.chen@example.sg").verified(true))
                .phone(new PhoneContact().value("+65-9123-4567").verified(true)))
            .addresses(new ArrayList<>(List.of(new Address()
                .type(Address.TypeEnum.HOME)
                .line1("8 Marina Blvd")
                .city("Singapore")
                .administrativeArea("Central")
                .postalCode("018981")
                .country("SG"))))
            .documents(new ArrayList<>(List.of(new IdentityDocument()
                .type(IdentityDocument.TypeEnum.DRIVER_LICENSE)
                .number("S9988776")
                .issuingCountry("SG"))))
            .segment(Party.SegmentEnum.PRIVATE)
            .status(Party.StatusEnum.ACTIVE)
            .riskRating(Party.RiskRatingEnum.LOW)
            .ownerId("cust-3003")
            .relationshipManagerId("rm-99")
            .region("APAC")
            .version(1)
            .updatedAt(OffsetDateTime.parse("2026-11-04T02:05:00Z"))
            .sourceSystems(new ArrayList<>(List.of("CORE", "WEALTH")))
            .consents(new ArrayList<>(List.of(
                new Consent().purpose(Consent.PurposeEnum.DATA_SHARING).granted(true).reference("CONSENT-91"))));

        save(jane);
        save(lars);
        save(mei);
    }
}
