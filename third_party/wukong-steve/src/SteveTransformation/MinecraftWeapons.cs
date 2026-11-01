using System;
using System.Collections.Generic;

namespace SteveTransformation;

// Java 1.21.11 item components and enchantment data. Distances are blocks and time is seconds.
internal static class MinecraftWeapons
{
    internal readonly struct Spear
    {
        internal readonly double Jab,Multiplier,Delay,Dismount,MinDismount,Knockback,Damage;
        internal readonly int BaseDamage;
        internal Spear(double jab,double multiplier,double delay,double dismount,double minDismount,double knockback,double damage,int baseDamage)
        {Jab=jab;Multiplier=multiplier;Delay=delay;Dismount=dismount;MinDismount=minDismount;Knockback=knockback;Damage=damage;BaseDamage=baseDamage;}
    }
    private static readonly Spear[] spears={
        new Spear(.65,.7,.75,5,14,10,15,1),new Spear(.75,.82,.7,4.5,10,9,13.75,2),
        new Spear(.85,.82,.65,4,9,8.25,12.5,2),new Spear(.95,.95,.6,2.5,8,6.75,11.25,3),
        new Spear(.95,.7,.7,3.5,10,8.5,13.75,1),new Spear(1.05,1.075,.5,3,7.5,6.5,10,4),
        new Spear(1.15,1.2,.4,2.5,7,5.5,8.75,5)};
    internal static bool IsMace(McItem item) => item>=McItem.Mace && item<=McItem.MaceBreachWind;
    internal static bool IsSpear(McItem item) => item>=McItem.WoodenSpear && item<=McItem.NetheriteSpearLungeII;
    internal static int Material(McItem item) => item<=McItem.NetheriteSpear?(int)item-(int)McItem.WoodenSpear:
        item<=McItem.NetheriteSpearLungeIII?(int)item-(int)McItem.WoodenSpearLungeIII:6;
    internal static Spear Stats(McItem item) => spears[Material(item)];
    internal static int Lunge(McItem item) => !IsSpear(item)||item<=McItem.NetheriteSpear?0:item==McItem.NetheriteSpearLungeI?1:item==McItem.NetheriteSpearLungeII?2:3;
    internal static int Density(McItem item) => item==McItem.MaceDensity || item==McItem.MaceDensityWind?5:0;
    internal static int Breach(McItem item) => item==McItem.MaceBreach || item==McItem.MaceBreachWind?4:0;
    internal static int WindBurst(McItem item) => item==McItem.MaceWindI?1:item==McItem.MaceWindII?2:
        item==McItem.MaceWindIII||item==McItem.MaceDensityWind||item==McItem.MaceBreachWind?3:0;
    internal static bool Enchanted(McItem item) => IsMace(item)&&item!=McItem.Mace || Lunge(item)>0;
    internal static double SmashBonus(double distance,int density)
    {
        if(distance<=1.5) return 0;
        return Math.Min(distance,3)*4+Math.Min(Math.Max(0,distance-3),5)*2+Math.Max(0,distance-8)+distance*.5*density;
    }
    internal static double WindMultiplier(int level) => level<=1?1.2:level==2?1.75:2.2;
    internal static double ChargeDamage(Spear spear,double attackerSpeed,double targetSpeed,double seconds)
    {
        double relative=Math.Max(0,attackerSpeed-targetSpeed),active=seconds-spear.Delay;
        return active>=0&&active<spear.Damage&&relative>=4.6?spear.BaseDamage+Math.Floor(relative*spear.Multiplier):0;
    }
    internal static bool ChargeKnockback(Spear spear,double speed,double seconds) => seconds>=spear.Delay&&seconds<spear.Delay+spear.Knockback&&speed>=5.1;
    internal static bool ChargeDismount(Spear spear,double speed,double seconds) => seconds>=spear.Delay&&seconds<spear.Delay+spear.Dismount&&speed>=spear.MinDismount;
    internal static double ArmorMultiplier(double reduction,int breach)
    {
        reduction=Math.Max(0,Math.Min(.8,reduction));
        return (1-reduction*(1-.15*breach))/(1-reduction);
    }
}

// A contact must separate before a spear can hit it again; the ten-tick cooldown alone is insufficient.
internal sealed class MinecraftSpearContacts<T> where T:notnull
{
    private readonly Dictionary<T,double> last=new Dictionary<T,double>();
    private readonly HashSet<T> previous=new HashSet<T>(),current=new HashSet<T>();
    internal void Begin() => current.Clear();
    internal bool Touch(T target,double now)
    {
        current.Add(target);
        if(previous.Contains(target) || last.TryGetValue(target,out double time)&&now-time<.5) return false;
        return true;
    }
    internal void Hit(T target,double now) {last[target]=now;previous.Add(target);}
    internal void End()
    {
        previous.IntersectWith(current);
        if(last.Count>256) last.Clear();
    }
    internal void Clear() {last.Clear();previous.Clear();current.Clear();}
}
