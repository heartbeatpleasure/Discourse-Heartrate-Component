import DiscourseRoute from "discourse/routes/discourse";

export default class LiveMetricsRoute extends DiscourseRoute {
  titleToken() {
    return "live_metrics.title";
  }
}
