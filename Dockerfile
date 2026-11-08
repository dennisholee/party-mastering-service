FROM alpine:3.24@sha256:3f4d6b32e26703c6082839234f43769d5046b3ac7c910033911d1e71d8cd630a
RUN apk add --no-cache openjdk21-jre-headless \
 && adduser -D -u 10001 party
COPY target/party-mastering-service-0.1.0.jar /app.jar
USER party
ENTRYPOINT ["java", "-jar", "/app.jar"]
