# Pricing a room that expires tonight
*A hotel room is the most perishable product in business: unsold at midnight, it is gone forever, and that one fact shapes every price a hotel sets.*

Walk past the front desk of any city hotel at six in the evening and you are looking at a shop whose shelves empty themselves at midnight. A room that no one sleeps in tonight cannot be stored, discounted next week or sold twice tomorrow. Economists call this **perishability**, and it is the reason hotels think about price so differently from a supermarket.

This idea leads straight to the tools revenue managers use every day: occupancy, average daily rate and the measure that combines them.

## Occupancy alone tells half the story

**Occupancy** is the share of available rooms that were sold. A 200-room hotel that sells 160 rooms is at 80 percent. It is the number managers quote first, and it is easy to push up: cut the price far enough and the hotel fills.

That is exactly why it misleads. A full hotel at a giveaway rate can earn less than a three-quarters-full hotel at a healthy one. Occupancy measures how busy you are, not how well you are doing.

:::slide
- Occupancy = rooms sold ÷ rooms available
- Easy to raise: just cut the price
- Measures how busy, not how well
:::

:::course
Your course calls this the *volume trap*: chasing occupancy with discounts until rate collapses. The lecture's example is a resort that reached 95 percent in August and still missed its budget.
:::

## Average daily rate is the other half

The **average daily rate** (ADR) is room revenue divided by rooms sold. If those 160 rooms earned $19,200, the ADR is $120. Rate is the mirror image of occupancy: easy to raise by refusing cheap business, at the cost of empty rooms.

| Measure | Formula | Moves up when | Risk |
|---|---|---|---|
| Occupancy | rooms sold ÷ rooms available | prices fall | rate collapses |
| ADR | room revenue ÷ rooms sold | prices rise | rooms go empty |
| RevPAR | room revenue ÷ rooms available | both balance | none on its own |

## RevPAR brings them together

Revenue per available room puts both halves into one number:

\[ \text{RevPAR} = \text{ADR} \times \text{Occupancy} = \frac{\text{room revenue}}{\text{rooms available}} \]

Because the denominator is every room the hotel *could* have sold, empty rooms count against you and so do cheap ones. That is what makes \(\text{RevPAR}\) the measure owners compare across hotels.

:::example Two Tuesdays at the same hotel
On the first Tuesday the hotel sells 180 of 200 rooms at $90: occupancy 90 percent, ADR $90, RevPAR $81. On the second it sells 150 rooms at $115: occupancy 75 percent, ADR $115, RevPAR \(0.75 \times 115 = 86.25\). The emptier night earned more per room.

```diagram
{"kind":"flow","title":"How a revenue manager reads a night","steps":["Forecast demand","Set the price","Watch the pickup","Adjust the rate"],"cycle":true}
```
:::

## Why demand curves matter here

Every price sits on a demand curve: lower prices fill more rooms, higher prices fewer. The revenue manager's job is to find the point on that curve where revenue per room is highest, and to move it as demand shifts.

```diagram
{"kind":"graph","title":"A demand shift on a festival weekend","x_label":"Rooms sold","y_label":"Price","curves":[{"label":"D","points":[[1,9],[9,1]]},{"label":"D′","points":[[3,9.5],[9.5,3]],"dashed":true}],"arrows":[{"label":"festival","from":[5,5],"to":[6.4,6.4]}]}
```

When a festival comes to town the whole curve moves right: the same price now sells more rooms, so the hotel can raise its rate and still fill.

## A simple picture of the room inventory

```svg
<svg viewBox="0 0 300 80" xmlns="http://www.w3.org/2000/svg"><title>Tonight's 200 rooms</title><rect x="10" y="20" width="220" height="40" fill="none" stroke="black"/><rect x="230" y="20" width="60" height="40" fill="none" stroke="black"/><text x="120" y="45" text-anchor="middle">sold</text><text x="260" y="45" text-anchor="middle">empty</text></svg>
```

The empty block on the right is revenue the hotel can never recover. Everything in revenue management is an effort to make it smaller without giving the rest away.

## Check yourself

:::check
Q: Why can a hotel at 75 percent occupancy earn more than one at 90 percent?
A: Because revenue depends on rate as well as volume. If the emptier hotel's ADR is high enough, its RevPAR (ADR × occupancy) is higher.
Q: What makes a hotel room perishable?
A: It can't be stored: a room unsold tonight is revenue lost for good.
Q: What does RevPAR's denominator capture that ADR's doesn't?
A: Every available room, so empty rooms lower RevPAR while ADR ignores them.
:::

```cards
Q: Occupancy
A: Rooms sold ÷ rooms available: how busy the hotel is.
Q: ADR (average daily rate)
A: Room revenue ÷ rooms sold.
Q: RevPAR
A: Room revenue ÷ rooms available, or ADR × occupancy.
Q: Perishability
A: An unsold room-night can never be sold later.
```
