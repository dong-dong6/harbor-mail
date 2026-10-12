package com.itdong.mail;

import java.time.Clock;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
class DeviceSessionConfiguration {
  @Bean Clock sessionClock() { return Clock.systemUTC(); }
}
