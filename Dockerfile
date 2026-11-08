FROM alpine:3.20
RUN apk add --no-cache openjdk21-jre-headless \
 && adduser -D -u 10001 party
COPY target/party-mastering-service-0.1.0.jar /app.jar
USER party
ENTRYPOINT ["java", "-jar", "/app.jar"]
