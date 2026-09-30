# First run scripts/build.sh; dist/mail-client.jar contains the Flutter web app.
FROM eclipse-temurin:21-jre-jammy
WORKDIR /app
RUN groupadd --gid 10001 mailapp && useradd --uid 10001 --gid mailapp --no-create-home mailapp && mkdir -p /app/data && chown mailapp:mailapp /app/data
COPY --chown=mailapp:mailapp dist/mail-client.jar /app/mail-client.jar
USER mailapp
EXPOSE 8080
ENTRYPOINT ["java","-XX:MaxRAMPercentage=70.0","-jar","/app/mail-client.jar"]

