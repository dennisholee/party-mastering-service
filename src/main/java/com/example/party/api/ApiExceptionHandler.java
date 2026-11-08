package com.example.party.api;

import com.example.party.model.ErrorResponse;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.validation.FieldError;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.server.ResponseStatusException;

import java.util.stream.Collectors;

/**
 * Application-level error contract. Entitlement, DQ and masking failures are
 * produced by the sidecar before this handler is reached; these errors cover
 * business validation and mastering conflicts only.
 */
@RestControllerAdvice
public class ApiExceptionHandler {

    @ExceptionHandler(ResponseStatusException.class)
    public ResponseEntity<ErrorResponse> statusException(ResponseStatusException ex) {
        String reason = ex.getReason() == null ? "request_failed" : ex.getReason();
        return ResponseEntity.status(ex.getStatusCode())
            .body(new ErrorResponse().error(reason));
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<ErrorResponse> validation(MethodArgumentNotValidException ex) {
        String detail = ex.getBindingResult().getFieldErrors().stream()
            .map(this::fieldMessage)
            .sorted()
            .collect(Collectors.joining(", "));
        return ResponseEntity.badRequest()
            .body(new ErrorResponse().error("validation_failed").message(detail));
    }

    @ExceptionHandler(HttpMessageNotReadableException.class)
    public ResponseEntity<ErrorResponse> unreadable(HttpMessageNotReadableException ex) {
        return ResponseEntity.badRequest().body(new ErrorResponse().error("invalid_json"));
    }

    private String fieldMessage(FieldError error) {
        return error.getField() + ":" + (error.getDefaultMessage() == null ? "invalid" : error.getDefaultMessage());
    }
}
