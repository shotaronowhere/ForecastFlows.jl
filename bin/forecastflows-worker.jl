#!/usr/bin/env julia

using ForecastFlows
using JSON3

function main()
    for line in eachline(stdin)
        isempty(strip(line)) && continue
        response = ForecastFlows.prediction_market_worker_response(line)
        encoded = try
            JSON3.write(response)
        catch err
            JSON3.write((
                protocol_version=ForecastFlows.PREDICTION_MARKET_WORKER_PROTOCOL_VERSION,
                request_id=hasproperty(response, :request_id) ? getproperty(response, :request_id) : nothing,
                ok=false,
                error=(
                    code="internal_error",
                    message="failed to encode worker response: $(sprint(showerror, err))",
                ),
            ))
        end
        println(stdout, encoded)
        flush(stdout)
    end
end

main()
