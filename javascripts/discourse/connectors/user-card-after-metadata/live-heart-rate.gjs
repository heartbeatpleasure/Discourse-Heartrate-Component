import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";

export default class LiveHeartRateUserCard extends Component {
  @service liveMetricsUserCards;

  registrationKey = null;
  surface = "user_card";

  get username() {
    return this.args.outletArgs?.user?.username;
  }

  get reading() {
    return this.liveMetricsUserCards.readingFor(this.username, this.surface);
  }

  get bpmLabel() {
    return this.reading ? `${this.reading.heart_rate} BPM` : "";
  }

  get ariaLabel() {
    return this.reading
      ? `Live heart rate ${this.reading.heart_rate} beats per minute`
      : "";
  }

  @action
  setup(element) {
    this.surface = element.closest(".user-card-directory")
      ? "directory"
      : "user_card";
    this.registrationKey = this.liveMetricsUserCards.register(
      this.username,
      this.surface
    );
  }

  willDestroy() {
    if (super.willDestroy) {
      super.willDestroy(...arguments);
    }

    this.liveMetricsUserCards.unregister(this.registrationKey);
  }

  <template>
    <div
      class="live-metrics-user-card-slot {{if this.reading 'has-reading'}}"
      {{didInsert this.setup}}
    >
      {{#if this.reading}}
        <div
          class="live-metrics-user-card-reading"
          aria-label={{this.ariaLabel}}
        >
          <span class="live-metrics-user-card-reading__heart" aria-hidden="true">♥</span>
          <span class="live-metrics-user-card-reading__measure">
            <span class="live-metrics-user-card-reading__label">Heart rate</span>
            <strong class="live-metrics-user-card-reading__value">{{this.bpmLabel}}</strong>
          </span>
          <span class="live-metrics-user-card-reading__status">
            <span class="live-metrics-user-card-reading__dot" aria-hidden="true"></span>
            Live now
          </span>
        </div>
      {{/if}}
    </div>
  </template>
}
